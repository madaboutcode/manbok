# Runtime troubleshooting (read when daemon/IPC misbehaves)

## Symptom: `status` → `stopped` but `start` → `already listening`

Orphan daemon: process alive, capture stopped. **Fix:** `upil-appa stop` then `start`, or let `start` replace stale listener (sends `STOP`, respawns).

## Symptom: `dump` → `not listening`

Daemon not capturing. Run `upil-appa authorize` from Terminal (same binary as the daemon, e.g. `~/.local/bin/upil-appa`). Check Console.app filter `subsystem:ai.upil.appa`. Restart after granting.

## Symptom: connect errors

```bash
ls -la ~/.upil-appa/
cat ~/.upil-appa/appa.pid
ps -p "$(cat ~/.upil-appa/appa.pid)"
```

Remove stale state only when pid is dead:

```bash
rm -f ~/.upil-appa/run.sock ~/.upil-appa/appa.pid
```

## IPC debug

```bash
printf 'STATUS\n' | nc -U ~/.upil-appa/run.sock
printf 'PING\n' | nc -U ~/.upil-appa/run.sock
```

## LaunchAgent vs Terminal `make start`

Poor or garbled audio **only under launchd** is usually a **session / HAL routing** issue, not “no mic permission.”

| How started | Audio context |
|-------------|----------------|
| `upil-appa start` from Terminal | Child inherits your **GUI (Aqua) session** — same class as an app you launched |
| `~/Library/LaunchAgents/*.plist` | OK **if** `LimitLoadToSessionType` = `Aqua` and `ProcessType` = `Interactive` |
| `/Library/LaunchDaemons/*.plist` | **Wrong** for mic — system context, degraded or silent capture |

**Do not** run `upil-appa daemon` from a system LaunchDaemon. Use a **user LaunchAgent** (template: `resources/com.upil.appa.plist`).

Before enabling the agent:

1. `upil-appa authorize` from Terminal (TCC prompt needs a user session).
2. Replace `REPLACE_WITH_UPIL_APPA_PATH` in the plist (e.g. `~/.local/bin/upil-appa`).
3. Install: `make install-launchagent` (or copy `resources/com.upil.appa.plist` and `launchctl bootstrap gui/$(id -u) …`)

Compare capture lines in Console:

```text
capture started device format: … Hz, ch=…, format=… → 16000 Hz mono s16
external mic activity — capturing from <device name>
```

If launchd shows a different **device name** or **format** than Terminal, you are not on the same input path. Bluetooth headsets under background co-capture often stay on **16 kHz HFP** and sound worse when Zoom and appa share the mic.

**Workaround:** skip launchd for now — `make install` then `make start` (or `upil-appa start`) from login, or a Login Item that runs `upil-appa start` after you log in.

## Logs

Detached `make start` stdio → `/dev/null`. LaunchAgent logs → `/tmp/upil-appa.stderr.log` if using the template plist. Otherwise **Console.app** → `subsystem:ai.upil.appa`. Foreground `upil-appa daemon` mirrors important lines to stderr.

### Stop-detection trace (`[trace]`)

After `make build`, run `make dev`, reproduce (start/stop recording in Zoom etc.), then in **Console.app**:

- Filter: `subsystem:ai.upil.appa` and message contains `[trace]`
- Or from a terminal (if `log` is not shadowed by a shell alias):

```bash
log stream --predicate 'subsystem == "ai.upil.appa" AND eventMessage CONTAINS "[trace]"' --style compact
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