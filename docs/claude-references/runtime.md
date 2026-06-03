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