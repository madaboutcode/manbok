# test-harness

Controllable macOS mic capture process for validating manbok's capture pipeline. Not a
spike — this is permanent test infrastructure. Use it as a stimulus when testing
device-following, silence recovery, or process-monitor behavior.

## When to Use

- Validating that manbok's capture supervisor follows device changes correctly
- Testing silence recovery behavior (mute, vol=0, device zombies)
- Regression testing capture pipeline changes — replay scenarios against rebuilt components
- Probing pdv# visibility: does a process holding a mic show up in process→device queries?
- Investigating device metadata (transport type, IsRunningSomewhere, mute/volume properties)

## Commands

```bash
cd tools/test-harness
swift build                                    # build
swift run test-mic-harness <scenario-name>     # run (scenario name required)
```

The scenario name scopes the socket and log file — parallel runs don't collide:
- Socket: `/tmp/test-mic-harness-<scenario>.sock`
- Log: `/tmp/test-mic-harness-<scenario>.log` (NDJSON, one event per line)

## Socket Protocol

Send commands via: `echo "CMD" | nc -U /tmp/test-mic-harness-<scenario>.sock`

Each command is a single line. Response is one or more lines. One connection per command.

| Command | Response | What it does |
|---------|----------|-------------|
| `DEVICES` | One line per input device: id, transport, name, runningSomewhere, vol, mute | List all input devices with HAL metadata |
| `START <substring>` | `OK started on <name> [<id>]` or `ERR <reason>` | Pin AUHAL capture to device matching substring (case-insensitive) |
| `STOP` | `OK stopped` | Stop capture |
| `SWITCH <substring>` | `OK switched to <name> [<id>]` | Stop current + start on new device |
| `STATUS` | JSON object | Current state + live audio stats (see below) |
| `MUTE` | `OK muted (vol 0.0, was <prev>)` or `ERR already muted` | Set device input volume to 0.0, save previous |
| `UNMUTE` | `OK unmuted (vol <restored>)` | Restore saved volume |
| `VOL <0.0-1.0>` | `OK vol=<value>` | Set specific input volume |
| `QUIT` | `OK bye` | Restore volume, stop capture, remove socket, exit |

### STATUS response

```json
{
  "state": "capturing",
  "device": "MacBook Pro Microphone",
  "deviceId": 113,
  "peak": 1234,
  "rms": 0.0312,
  "zeroPercent": 0.0,
  "zeroRunMax": 0,
  "everSignaled": true,
  "uptimeSeconds": 42
}
```

`everSignaled` is the key metric for the silence recovery redesign: `true` once any
non-zero sample has been seen since this worker started. Distinguishes "device path was
dead from the start" (never signaled → kick) from "was working, then went silent"
(signaled → immediate hold, no restarts).

## Safety

- Volume is restored on QUIT, SIGINT, and SIGTERM
- Double-MUTE is guarded (returns `ERR already muted`, won't overwrite saved volume)
- Socket file is cleaned up on all exit paths
- TCC permission is checked before capture — exits with a clear error if mic access denied

## Per-Second Stats (stderr)

While capturing, the harness prints one stats line per second to stderr:
```
[HH:MM:SS] peak=<int16> rms=<float> zeros=<count>/<total> (<pct>%) zeroRun=<cur>/<max> everSignaled=<bool>
```

## JSON Event Log

Every event is appended to the log file as NDJSON:
```json
{"ts":"2026-07-08T08:30:00.000Z","scenario":"vol-zero-test","event":"started","device":"MacBook Pro Microphone","deviceId":113}
{"ts":"...","scenario":"vol-zero-test","event":"muted","device":"MacBook Pro Microphone","prevVol":0.43}
{"ts":"...","scenario":"vol-zero-test","event":"unmuted","device":"MacBook Pro Microphone","restoredVol":0.43}
{"ts":"...","scenario":"vol-zero-test","event":"stopped"}
```

## Example: Scripted Test Scenario

```bash
# Terminal 1: start harness
cd tools/test-harness && swift run test-mic-harness "mute-test"

# Terminal 2: drive the scenario
SOCK=/tmp/test-mic-harness-mute-test.sock
echo "START MacBook" | nc -U $SOCK        # start capturing
sleep 5                                    # let it run
echo "STATUS" | nc -U $SOCK               # check everSignaled
echo "MUTE" | nc -U $SOCK                 # set vol=0
sleep 10                                   # observe zero patterns
echo "STATUS" | nc -U $SOCK               # check stats during mute
echo "UNMUTE" | nc -U $SOCK               # restore volume
sleep 5                                    # observe recovery
echo "QUIT" | nc -U $SOCK                 # clean shutdown
```

## Companion Tools (in spikes/)

These probes run alongside the harness to observe its effect:

- **device-truth-spike** — polls HAL device metadata every 1s. Run it while the harness
  captures to see if `IsRunningSomewhere` flips, how pdv# reports the harness process, etc.
- **silence-probe-spike** — AUHAL capture with zero-sample analysis. Run on the same device
  as the harness to observe silence patterns under different conditions.

These live in `spikes/` (validation experiments). If they prove permanently useful they
graduate here.
