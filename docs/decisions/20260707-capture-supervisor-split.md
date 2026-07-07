# Capture architecture: lifecycle/supervisor split + disposable workers + dual watchdogs

**Date:** 2026-07-07
**Status:** decided (stakeholder: "I approve option B")
**Scope:** capture-redesign cycle (tasks/2026-07-07-capture-redesign/design.md is the
full design with candidates; this records the durable commitments).

## Considered

1. **A — minimal evolution:** keep CaptureOrchestrator as one component; add device
   policy + new backend inside it.
2. **B — supervisor split:** split the orchestrator on the volatility seam —
   SessionLifecycleController (set-diff/drain/registry/UI, stable) and CaptureSupervisor
   (worker lifecycle, watchdogs, restart budget, device targeting, volatile). Thin waist
   between them: demand down, isCapturing up. Capture attempts are disposable workers —
   created, pinned, run, abandoned; never repaired in place.
3. **C — pipeline redesign** (long-lived engine, tap→processing-queue decoupling), per
   the adversarial review's original sketch.

## Chosen

B, with two health checks in the supervisor: byte-flow watchdog (stalls) and
digital-silence watchdog with a bounded recovery ladder (zero-valued audio) —
spec: docs/specs/capture.md R4–R7.

## Why

Volatility cut: macOS audio quirks churn (every finding this cycle was one); session
semantics don't. The split contains OS churn in one component. Disposable workers match
the spike-proven recovery primitive (fresh instance recovers in ~50ms where in-place
repair never does) and make the audited data race structurally impossible (all worker
state instance-local). C was rejected on measurement: its premises (frame loss from
sink blocking, zero-PCM from tap mechanics, long-lived-engine safety) all tested false
(TapLoadSpike: 0 frames lost under 230MB stalls; VpioContentionSpike: stall not zeros;
2026-07-06 spike: fresh-engine restart is the mechanism that works).

## Limitations

- One more component and one interface (the waist) to keep honest.
- Silence thresholds (10s window, 2 restarts, exact-zero test) are judgment defaults.
- Stall-recovery numbers rest on n=1-per-event spike trials for the mid-call restart
  race; backoff + watchdog are the backstop if the ~50% DOA race bites in practice.

## Reversal

- Collapse B into A if, during implementation, the waist needs crossing awkwardly more
  than once (state or calls that don't fit demand-down/isCapturing-up).
- Revisit the silence ladder if production shows a false positive (unmuted live mic
  held) or false negative (sustained zeros unflagged) — thresholds move first, shape
  second.
- Revisit C's decoupling only if production logging ever shows tap-side frame loss.
