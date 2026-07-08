# spikes/

Validation experiments for manbok. Each spike is a standalone Swift executable that probes
macOS audio API behavior and prints observable results. Run from this directory:
`cd spikes && swift run <spike-name>`.

## Commands

```bash
swift build                              # build all spikes
swift build --product <name>             # build one spike
swift run <name> [args]                  # build + run
```

## Capture Test Infrastructure

The test-mic-harness (controllable capture process) has graduated to `tools/test-harness/` —
see its CLAUDE.md there for the full protocol and usage.

The following probe spikes run alongside the harness to observe macOS audio behavior:

### device-truth-spike — HAL device metadata poller

Polls all input devices every 1s and prints changes. Validates whether HAL metadata is
trustworthy for fallback device ranking.

```bash
swift run device-truth-spike [seconds]     # default 60s
```

**What it probes per device:** name, id, transport type (builtin/usb/bluetooth/etc),
default-input flag, `IsRunningSomewhere`, `IsRunning`, mute (input scope), volume scalar.
Plus pdv# process→device mapping (which PIDs hold which input devices).

**When to use:** when validating `IsRunningSomewhere` reliability, transport-type decoding,
or mute/volume property support across devices. Run alongside test-mic-harness or real apps
(Voice Memos, Zoom, browser) and watch which columns change.

### silence-probe-spike — AUHAL zero-sample analyzer

AUHAL pinned capture with per-second zero-sample statistics. Two modes:

```bash
# watch mode: capture + stats + stdin event markers
swift run silence-probe-spike watch --device <substring> [seconds]

# cycles mode: repeated start/stop measuring startup grace
swift run silence-probe-spike cycles <N> --device <substring>
```

**Watch mode stats (per second):** peak, RMS, exact-zero count/total (%), current zero-run,
max zero-run, everSignaled flag. Press any key to insert a timestamped marker in the output
(mark events like "muted now", "switched app"). Exit summary: histogram of zero/signal
seconds, max continuous zero-run, startup grace timing.

**Cycles mode:** starts/stops AUHAL N times, measures time-to-first-callback and
time-to-first-nonzero-sample per cycle, prints min/max/mean/p95 summary.

**When to use:** when you need empirical data about silence patterns — does a healthy mic
produce sustained exact zeros? How long is AUHAL startup grace? Does vol=0 produce exact
zeros or analog noise floor? Run while toggling mute/volume/devices to characterize
behavior.

## Spike Conventions

- Each spike is a standalone `main.swift` in `Sources/<SpikeName>/`.
- Register in `Package.swift` (product + target, `dependencies: []`).
- Header comment: hypothesis, run command, manual scenario script.
- No dependencies on manbok's own modules — spikes probe the OS, not our code.
- Results go in `README.md` results table with date and PASS/FAIL/MANUAL.

## Existing Spikes

See `README.md` for the full index and results. Key ones for the capture redesign:

| Spike | What | Status |
|-------|------|--------|
| pinned-capture-spike | AUHAL vs AVCaptureSession: can they hold a pinned non-default device? | PASS (both) |
| vpio-contention-spike | Does VPIO (calls) disrupt pinned capture? | PASS (survives) |
| tap-load-spike | Does queue.sync sink drop frames under checkpoint load? | PASS (zero loss) |
| device-spike | Default input device change listener | PASS |
| device-usage-spike | `IsRunningSomewhere` polling | PASS |
| device-switch-spike | AVAudioEngine pinned device — proved it can't hold (led to AUHAL) | FAIL (by design) |
