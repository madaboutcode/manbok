# Capture worker — pinned audio capture boundary

**Spec ID:** capture-worker
**Lifecycle:** living (interface spec). Source of truth for the `PinnedAudioCapturing`
protocol boundary and its associated types.
**Functional spec:** `capture.md` (R1–R9, device selection + self-healing from the user's
seat). This spec covers the programmatic contract at validation precision.
**Design source:** `tasks/2026-07-07-capture-redesign/design.md` §11.2.
**Decision records:** `docs/decisions/20260707-capture-follows-app-mic.md` (device
following); the backend winner (AUHAL vs AVCaptureSession) is pending P1–P5.

---

PURPOSE — what a consumer of the capture worker boundary observes: how to start and stop
a pinned audio capture, what the worker delivers, and what it does not do. The one
consumer is the capture supervisor; these types also flow through the waist
(`capture-waist.md`) indirectly via the status it returns.

CONTENTS — Target (W1) · Chunk (W2–W3) · Error (W4–W6) · Start/stop (W7–W12) ·
Bound device (W13) · Edge cases · Verification.

SCOPE — the worker protocol boundary only. Device *selection* policy: `capture.md`
R1–R3. Restart policy, watchdogs, silence recovery: `capture-waist.md` (supervisor
side). Functional behavior from the user's seat: `capture.md`. Terms: Mic, Session,
Ring, PCM stream per `glossary.md`.

## REQUIREMENTS

### Target

- W1 — A capture target is one of two kinds: **system default** (resolve the current
  default input device at start, bind concretely) or **device** (a specific audio device
  ID — pin exactly). Device IDs are unstable across Bluetooth reconnects; callers resolve
  fresh each start and never persist an ID.

### Chunk delivery

- W2 — While running, the worker delivers chunks to its sink callback. Each chunk carries
  the canonical PCM stream (`glossary.md`: mono 16 kHz 16-bit little-endian) regardless
  of the device's native sample rate or channel count. A native-format change mid-capture
  (e.g. 1↔3 channels when a call engages voice processing) is absorbed: the converter
  the worker absorbs the change, losing at most the buffer in which the format flipped;
  subsequent chunks resume in canonical format.
- W3 — Each chunk carries a peak sample value. Peak is exactly zero if and only if every
  sample in the chunk is exactly zero. A quiet-but-nonzero signal always produces a
  nonzero peak (`capture.md` R6).

### Errors

- W4 — Starting a worker can fail with one of three typed errors:
  - **permission denied** — microphone permission not granted.
  - **device unavailable** — the pinned device is absent or unusable at start time
    (carries the device ID).
  - **backend failure** — the audio backend reported an error (carries a description
    including the OS status code).
- W5 — Mid-run device death (device removed, powered off, reconfigured fatally) produces
  **silence of callbacks** — no error, no crash, just no more chunks. Detection is the
  supervisor's watchdog responsibility, not the worker's.
- W6 — If an individual buffer cannot be converted to canonical format, it is absorbed:
  logged at warning level, the buffer is dropped, capture continues. No chunk is
  delivered for the dropped buffer.

### Start and stop

- W7 — A worker instance is **disposable**: exactly one `start` per instance. A restart
  means creating a new instance. Calling `start` a second time on the same instance is a
  programming error (precondition failure).
- W8 — `start` takes a target and a sink callback. On success, the worker begins
  delivering chunks on its own delivery thread.
- W9 — `stop` is an idempotent barrier. After `stop` returns: no further sink calls
  occur; teardown is complete. Calling `stop` multiple times is safe.
- W10 — The sink callback must be fast or dispatch internally. The worker calls it on the
  audio delivery thread; blocking it blocks audio delivery.
- W11 — All mutable state is instance-local, touched only by the delivery thread after
  start. No shared mutable state across worker instances.
- W12 — `start` and `stop` are called from one caller thread (the supervisor's tick
  context). No concurrent start/stop calls.

### Bound device

- W13 — After a successful start, the worker exposes the concrete audio device it bound
  to (non-nil, constant until stop). For a system-default target, this is the device that
  was the default at start time. For a device target, this is that device. The supervisor
  uses this for logging (R9) and for environment signal targeting.

## EDGE CASES

- WE1 — System-default target when no input device exists: `start` throws device
  unavailable (there is no device to resolve to).
- WE2 — Device nominal sample rate read at start, never cached: a Bluetooth device that
  reconnects at a different rate gets the correct rate on the next worker instance.
- WE3 — The sink receives chunks from the delivery thread. If the sink dispatches to
  another queue, ordering is the sink's responsibility.

## VERIFICATION

Exercised by manual P1–P5 (`capture.md` VERIFICATION) and scenario runs against the
product build. Not unit-tested in isolation (hardware dependency); the protocol is
exercised through the supervisor's tests with fake worker implementations.
