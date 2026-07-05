# Configurable ring buffer duration

**Date:** 2026-07-04 · **Cycle:** tasks/2026-07-04-menubar-app/ · **Status:** decided

**Considered:** fixed 10-min ring (status quo); config-file/CLI-only setting; GUI setting with
hard 30/60-min memory cap; GUI setting with large ceiling and visible cost.

**Chosen:** Buffer duration becomes a user setting in the menu bar app. Presets 5/10/30/60/120
minutes, default 10. Memory cost (~1.9 MB/min) is displayed next to each preset — the trade-off
is the user's, made informed. Changing the setting resizes the ring immediately, preserving the
newest audio that fits (shrinking keeps the newest tail; sessions whose audio falls off vanish
from the list, same rule as ring wrap).

**Why:** The driving job is recovering things said in meetings/calls, which run up to an hour;
beyond that, memory is an acceptable, user-owned trade-off (stakeholder, 2026-07-04). This
**retires ARCHITECTURE.md Invariant 1** ("buffer length never exceeds 10 minutes") and the
"~19.2 MB RAM" constraint: capacity is now user-chosen up to 120 min (~230 MB). Retirement is
deliberate, not drift.

**Limitations:** No arbitrary/custom durations in v1 — presets only. Persistence mechanism is a
design-altitude call, not part of this decision.

**Reversal:** If anyone needs >120 min, extend the preset list — cheap. If resize-preserve
proves too complex in practice, fall back to clear-on-resize (product accepted data loss was
worse; revisit only with evidence).
