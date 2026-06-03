# Runtime troubleshooting (read when daemon/IPC misbehaves)

## Symptom: `status` → `stopped` but `start` → `already listening`

Orphan daemon: process alive, capture stopped. **Fix:** `upil-appa stop` then `start`, or let `start` replace stale listener (sends `STOP`, respawns).

## Symptom: `dump` → `not listening`

Daemon not capturing. Check mic permission for the **daemon** process (Console.app filter `subsystem:ai.upil.appa`). Restart after granting.

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

## Logs

Detached daemon stdio → `/dev/null`. Use **Console.app** → `subsystem:ai.upil.appa`. Foreground `upil-appa daemon` mirrors important lines to stderr if run manually for debugging.

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
| `hypothesis=H1-no-speech-yet` | No speech frame yet (`speechQuiet=inf`) |
| `release-probe RESUME` … `hypothesis=H2-…` | Probe ran; device still busy — capture resumed |
| `release-probe SESSION-END` … `hypothesis=ok-stop` | Clean stop |
| `watching ringGROWTH=` … `H4-…` | Ring grew while not capturing (bug) |
| `ringDeltaWhileStopped=` non-zero | PCM appended after engine stop (bug) |