# Capture waist — lifecycle-to-supervisor boundary

**Spec ID:** capture-waist
**Lifecycle:** living (interface spec). Source of truth for the waist boundary between
session lifecycle and capture supervision.
**Functional spec:** `capture.md` (R1–R9). This spec covers the programmatic boundary at
validation precision.
**Design source:** `tasks/2026-07-07-capture-redesign/design.md` §11.1, §11.5, §11.6.
**Decision records:** `docs/decisions/20260707-capture-supervisor-split.md` (Candidate B
split); `docs/decisions/20260707-capture-follows-app-mic.md` (device following).

---

PURPOSE — what a consumer of the capture waist observes: how lifecycle tells the
supervisor what to capture, and what it learns back. The waist is the single boundary
between session lifecycle (the stable half — sessions, drain, app identity) and capture
supervision (the volatile half — workers, devices, watchdogs, recovery). It enforces
that lifecycle never touches audio backends, and the supervisor never touches sessions.

CONTENTS — Demand (C1–C4) · Status (C5–C8) · Protocol (C9–C14) · Lifecycle
(C15–C19) · Edge cases · Verification.

SCOPE — the waist types and the `apply` protocol. Worker internals: `capture-worker.md`.
Device selection policy details: `capture.md` R1–R3. Silence recovery ladder:
`capture.md` R5/R6 STATES. Session semantics: `glossary.md` + `overview.md`. Terms: Mic,
Session, Ring, PCM stream, drain per `glossary.md`.

## REQUIREMENTS

### Demand

- C1 — Demand is a list of entries, one per external app currently holding the mic. Each
  entry carries: the app's bundle ID, a representative process ID (the most recently
  seen), and an arrival timestamp.
- C2 — The arrival timestamp marks the first poll tick of the app's current
  session-continuous presence. It is **preserved across a depart-and-reclaim within
  drain**: if an app releases the mic and reclaims it before its drain grace expires, the
  original arrival time stands — process-list flicker does not move the device-selection
  tie-break (`capture.md` R2).
- C3 — The arrival timestamp resets only when the app departs AND its drain actually
  expires (the session closes). The next arrival is a fresh presence.
- C4 — An empty demand list means no app holds the mic. The supervisor releases the
  worker (no more audio delivery) and resets policies. This release-on-empty-demand is
  distinct from a mid-recovery stop-and-restart: it ends the capture run entirely.

### Status

- C5 — After processing demand, the supervisor returns a status containing two fields:
  whether capture is currently active, and the current health. Capture is active when a
  worker is running in its normal lifecycle (not released due to empty demand — see C4).
- C6 — Health is one of four values:
  - **idle** — no demand, no worker running.
  - **capturing** — worker running, no recovery condition active.
  - **recovering** — a restart is pending or in backoff (triggered by stall, silence, or
    target change).
  - **holding silent** — the silence-recovery ladder is exhausted (`capture.md` R5
    Holding state): capture continues, but the input is treated as legitimately
    muted/idle and no further restarts are attempted until signal returns or conditions
    change.
- C7 — The "is capturing" field is the gate for arrival deferral: when it is false,
  lifecycle leaves newly arrived apps unseen so the next poll tick retries them. This
  prevents opening a session before capture can deliver audio for it.
- C8 — Health and "is capturing" are independent: "is capturing" reflects whether a
  worker is running at apply return, regardless of health. A worker may be running while
  health is recovering (restart pending but worker still delivering) or holding silent
  (worker continues, no more restarts). Health flows up for display and logging only.
  Lifecycle does not interpret health values to make session decisions — it reads only
  the "is capturing" field.

### Protocol — the apply call

- C9 — The waist has exactly one downward call: lifecycle passes the current demand list
  and the current time, and receives the post-decision status back. This is the
  supervisor's only entry point from lifecycle.
- C10 — The call is **synchronous**: the returned status reflects decisions made during
  this tick (worker started, stopped, restarted, health updated). No deferred callbacks,
  no async completion.
- C11 — The call happens every poll tick (~2s), not only on demand change. The tick is
  the supervisor's heartbeat — all periodic checks (stall detection, silence evaluation,
  target re-resolution, environment signal processing) run inside it.
- C12 — The supervisor expects all calls (apply, start, stop) to arrive serialized by
  the caller. Serialization is by ordering, not by queue identity — the supervisor does
  not assert which queue it runs on.
- C13 — On lifecycle stop, a final apply with an empty demand list is sent through the
  waist. This is how the worker is released — no second channel. The composition root
  then calls the supervisor's own stop (deactivating environment signals, resetting
  policies).
- C14 — The supervisor's start is called before lifecycle's start; the supervisor's stop
  is called after lifecycle's stop returns. Lifecycle's start/stop are synchronous on its
  queue, so composition-root ordering establishes happens-before with every tick.

### Lifecycle behavior at the waist

- C15 — Lifecycle owns the poll timer (~2s) on its serial queue. Each tick: snapshot
  running processes, compute set-diff against previous demand, call apply, process
  arrivals and departures.
- C16 — Arrival (new bundle ID in demand): cancel any pending drain timer for that app,
  open a session in the registry. **Arrivals are deferred while status.isCapturing is
  false** (C7) — left unseen so the next tick retries them.
- C17 — Departure (bundle ID no longer in demand): start a per-app drain timer (grace
  period, default 5s). If the app reclaims the mic before the timer fires, the timer is
  cancelled, the session continues, and the arrival timestamp is preserved (C2). If the
  timer fires, the session closes.
- C18 — `anySessionOpen` is true when the registry has any open session OR any drain
  timer is still running. This is the one signal that drives the menu bar icon state
  (Recording vs Watching, per `glossary.md`). Updated on the main thread.
- C19 — Mic permission is refreshed at 30s intervals via the injected permission check
  and published for the popover's permission state display.

## EDGE CASES

- CE1 — Supervisor start throws on the worker: status returns isCapturing=false; arrivals
  defer; retry happens on the next tick at the restart budget's pace.
- CE2 — Process snapshot returns no devices for any demanded app: device policy falls back
  to system default (`capture.md` R1 fallback, E2). The digital-silence guard (R5) is
  the safety net.
- CE3 — Demand transitions from non-empty to empty: worker is released (C4), no audio
  delivered. Drain keeps sessions open WITHOUT a worker — the mic indicator turns off.
  If demand returns within drain grace, a new worker starts on the next tick.
- CE4 — Multiple apps arrive on the same tick: all are processed; device policy resolves
  a single target from the combined demand.
- CE5 — Lifecycle stop while a drain timer is running: the timer is cancelled, the
  session is closed, the final empty-demand apply releases the worker.

## STATES

The waist itself is stateless — it is a call protocol. For the silence-recovery ladder
(which the supervisor runs internally, observable through health), see `capture.md`
STATES. For session states (open/draining/closed/expired), see `glossary.md` +
`overview.md`.

## VERIFICATION

**Waist boundary enforcement:** a source-scan test reads `SessionLifecycleController.swift`
and fails if it contains any identifier from the capture side's vocabulary (worker types,
policy types, backend types, device types). This machine-enforces that lifecycle's only
capture knowledge is the waist types. The denylist and allowlist are maintained in the
test.

**Functional verification:** the waist protocol is exercised through:
- Unit tests with fake supervisors (lifecycle side) and fake workers/snapshots
  (supervisor side) — no hardware.
- Manual P1–P5 (`capture.md` VERIFICATION) exercises the full stack end-to-end.
- Scenario runs per the design's validation scenarios (§9).
