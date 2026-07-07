# Runtime troubleshooting (read when daemon/IPC misbehaves)

## Symptom: `status` → `stopped` but `start` → `already listening`

Orphan daemon: process alive, capture stopped. **Fix:** `manbok stop` then `start`, or let `start` replace stale listener (sends `STOP`, respawns).

## Symptom: `dump` → `not listening`

Daemon not capturing. Run `manbok authorize` from Terminal (same binary as the daemon, e.g. `~/.local/bin/manbok`). Check Console.app filter `subsystem:ai.manbok.app`. Restart after granting.

## Symptom: connect errors

```bash
ls -la ~/.manbok/
cat ~/.manbok/appa.pid
ps -p "$(cat ~/.manbok/appa.pid)"
```

Remove stale state only when pid is dead:

```bash
rm -f ~/.manbok/run.sock ~/.manbok/appa.pid
```

## IPC debug

```bash
printf 'STATUS\n' | nc -U ~/.manbok/run.sock
printf 'PING\n' | nc -U ~/.manbok/run.sock
```

## LaunchAgent vs Terminal `make start`

Poor or garbled audio **only under launchd** is usually a **session / HAL routing** issue, not “no mic permission.”

| How started | Audio context |
|-------------|----------------|
| `manbok start` from Terminal | Child inherits your **GUI (Aqua) session** — same class as an app you launched |
| `~/Library/LaunchAgents/*.plist` | OK **if** `LimitLoadToSessionType` = `Aqua` and `ProcessType` = `Interactive` |
| `/Library/LaunchDaemons/*.plist` | **Wrong** for mic — system context, degraded or silent capture |

**Do not** run `manbok daemon` from a system LaunchDaemon (system context, degraded capture).

**The LaunchAgent mechanism is retired.** The app is the long-lived process now; login
persistence is the app's Login Item (popover → Settings → "Start at login", via
`LoginItemManager`). `MigrationService` detects a legacy `com.manbok.app` LaunchAgent plist
at app launch, boots it out, and deletes it — so hand-installed agents will not survive.
The table above is kept for debugging session/HAL routing of the foreground daemon.

Compare capture lines in Console:

```text
capture started device format: … Hz, ch=…, format=… → 16000 Hz mono s16
external mic activity — capturing from <device name>
```

If launchd shows a different **device name** or **format** than Terminal, you are not on the same input path. Bluetooth headsets under background co-capture often stay on **16 kHz HFP** and sound worse when Zoom and appa share the mic.

**Workaround:** skip launchd for now — `make install` then `make start` (or `manbok start`) from login, or a Login Item that runs `manbok start` after you log in.

## Logs

Detached `make start` stdio → `/dev/null`. Diagnostics: **Console.app** → `subsystem:ai.manbok.app`. Foreground `manbok daemon` mirrors important lines to stderr.

### Stop-detection trace (`[trace]`)

After `make build`, run `make dev`, reproduce (start/stop recording in Zoom etc.), then in **Console.app**:

- Filter: `subsystem:ai.manbok.app` and message contains `[trace]`
- Or from a terminal (if `log` is not shadowed by a shell alias):

```bash
log stream --predicate 'subsystem == "ai.manbok.app" AND eventMessage CONTAINS "[trace]"' --style compact
```

| Log pattern | Hypothesis |
|-------------|------------|
| `releaseBlocked=1` … `hypothesis=H1-vad-not-quiet` | Speech VAD never stays quiet 2.5s — probe never runs |
| `hypothesis=H1-active-not-quiet` | PCM arrived but level stays above threshold (no 2.5s quiet) |
| `hypothesis=H1-no-audio-yet` | No PCM chunks yet (`speechQuiet=inf`, `activeQuiet=inf`) |
| `release-probe RESUME` … `hypothesis=H2-…` | Probe ran; device still busy — capture resumed |
| `release-probe SESSION-END` … `hypothesis=ok-stop` | Clean stop |
| `watching ringGROWTH=` … `H4-…` | Ring grew while not capturing (bug) |
| `ringDeltaWhileStopped=` non-zero | PCM appended after engine stop (bug) |