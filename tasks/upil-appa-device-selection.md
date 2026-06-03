# Input device selection — brainstorm + spike plan

**Problem:** Capture must follow the mic the user is actually on (e.g. AirPods after plug-in), not stay on stale built-in after default changes.

## What macOS actually exposes

| Signal | API | Trust |
|--------|-----|-------|
| System default input changed | `kAudioHardwarePropertyDefaultInputDevice` + property listener | **High** — public, stable |
| “App X is recording from device Y” | No public API | **No** — no Zoom/Meet/PID list |
| “Some client has IO on this input device” | `kAudioDevicePropertyDeviceIsRunningSomewhere` | **Partial** — device-level only; spike `device-usage-spike` |
| `kAudioDevicePropertyClientList` | Core Audio | **Count only** — object IDs, not app names |
| Input has non-silence / recent IO | Input metering, IO proc | **Heuristic** — “probably active” |
| AirPods became default | Usually same as row 1 when user plugs in | **High** for that case |

**Job to be done:** When the user moves to a new mic route, appa’s buffer should reflect that route without manual restart.

## Decision tree

```text
Need to follow user's mic
├── Can we read "recording app's device"? → NO (publicly)
├── Does default input change on plug/switch? → YES (usually)
│   └── Spike: property listener ✓
├── Need device before default updates? → sometimes lag
│   └── Phase 2: also listen kAudioHardwarePropertyDevices + hotplug
└── Default ≠ "what Meet is using" (rare edge)
    └── Phase 3: metering heuristic — pick device with signal
```

## Considered paths

```
Considered:   (A) fixed at daemon start  (B) follow default + hot-swap  (C) mirror "active recorder" via private/heuristic
Chosen:       (B) now, optional (C) later if B fails user tests
Why:          AirPods case is mostly default change; B is shippable with Core Audio listener + engine restart
Limitations:  Won't know Zoom's device if OS default differs; ~100–300ms gap on swap; ring has discontinuity at switch
Fine because:  primary scenario is plug headphones → new default
Reversal:     user reports wrong device while default is correct → invest in (C) metering spike
```

## Spike results (2026-06-03, user machine)

- `device-usage-spike`: `runningSomewhere` 0→1 when recording elsewhere — **PASS**
- `device-capture-spike`: idle→capture→peaks→release→idle — **PASS**

## Implemented

- Default mode: **opportunistic** (`OpportunisticCaptureController` + `InputDeviceObserver`)
- `upil-appa start --always-on`: legacy continuous capture
- `status`: `watching` | `listening` | `stopped`
- `dump`: works when ring has data even if not actively capturing

## Implementation sketch (post-spike)

1. **`InputDeviceMonitor`** (Platform) — Core Audio listener on default input; callback on main/serial queue.
2. **`AVAudioCapture`** — on change: `stop()` → re-bind `inputNode` (new engine or reset) → `start(sink:)`; log old/new name via `AppLog`.
3. **Ring buffer** — keep writing; optional 50ms silence at seam (v2).
4. **NOT in v1** — CLI `--device`, aggregate device creation.

## Spikes

| Spike | Pass criteria |
|-------|----------------|
| `device-spike` | Plug/switch input → stderr prints CHANGED with new device name within 2s |
| `device-capture-spike` | Wait 0→1 idle → capture + peaks → stop engine → verify 0 after other app stops |

Run:

```bash
cd spikes && swift run device-spike 60
```

Manual: switch Sound → Input, plug AirPods, observe CHANGED lines.