# Capture follows the session app's mic, not the system default

**Date:** 2026-07-07
**Status:** decided (stakeholder, in-session: "that should be the right fix irrespective
of the default" + "I want a proper fix")
**Scope:** capture-redesign cycle (tasks/2026-07-07-capture-redesign/). Graduates and
supersedes the interim record tasks/decisions-20260706-device-change-robustness.md
(same decision, now evidence-complete and spec-visible).

## Considered

1. Follow the system default input + self-healing restarts (the shipped interim).
2. Follow the session app's actual input device (per-app HAL resolution), default as
   fallback — requires replacing the AVAudioEngine backend, which cannot pin a device.
3. Capture all input devices simultaneously.

## Chosen

Option 2. The glossary's **Mic** evolves accordingly (was: "the system default input
device"); behavior spec: docs/specs/capture.md R1–R3.

**Multi-app rule (added at spec/design gate, 2026-07-07):** when concurrent session apps
use different devices, capture picks the device shared by the most apps, ties broken by
the most-recent arrival's device (capture.md R2). Ambiguity is deliberately NOT resolved
to the system default: a session app's real device always beats the default, because the
default can be exactly the zeros-producing idle device this decision exists to eliminate.

## Why

The job is "record what the meeting records." Option 1 records the wrong audio whenever
the default differs from the app's device — and the 2026-07-07 incident proved the worst
case: a full-length recording of digital zeros (default was a zeros-producing idle
device) while Firefox recorded fine on the built-in mic, with every health check green.
Users also pin mics per-app in Meet/Zoom; for them option 1 is wrong on every meeting.
Per-app resolution is spike-proven (2026-07-06: reliable, ~1s latency, tracks in-app
switches); both replacement backends (AUHAL post-fix, AVCaptureSession) are spike-proven
to hold a pinned device AND to survive other apps' voice-processing engagement/teardown
that permanently kills AVAudioEngine (2026-07-07, n=2 replication). Option 3 stays
rejected — one correct mic, not all mics.

## Limitations

- One device at a time; concurrent apps on different mics → deterministic pick
  (shared > most-recent), other session's audio is wrong-device (capture.md L2).
- 0.3–2s gap per device transition.
- Device IDs and nominal sample rates are unstable across BT reconnects → both resolved
  at use time, never cached (spike-proven constraint).
- Detection reports an open IO path, not flowing audio — a muted app looks identical.
  The digital-silence guard (20260707-capture-supervisor-split.md) is the safety net.

## Reversal

If no backend passes the manual P1–P5 runsheet (capture.md VERIFICATION), fall back to
shipping option 1 alone as an interim — explicitly, back through this record — while
escalating. Revisit option 3 only on a real user need to record two apps on two mics
simultaneously.
