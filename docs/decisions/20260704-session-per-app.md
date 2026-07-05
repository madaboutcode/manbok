# Session = one app's unbroken mic use (concurrent sessions allowed)

**Date:** 2026-07-04 · **Cycle:** tasks/2026-07-04-menubar-app/ · **Altitude:** domain
**Made with stakeholder** (ontology call, two grill rounds).

## Considered

1. **Unbroken-mic-run session, union identity** (shipped behavior): one session per unbroken
   stretch of *any* app(s) using the mic; identity is the flattened union ("FaceTime, OBS");
   back-to-back calls within the ~5 s drain grace merge into one session.
2. **Per-app, chop at every change:** close/reopen whenever the set of mic-holding apps
   changes; non-overlapping rows, but one call fragments across rows when another app dips in.
3. **Per-app, concurrent sessions:** one session per app, overlapping in time when apps
   overlap, each a view over the shared ring audio.

## Chosen

**Option 3.** A Session is one app's unbroken use of the microphone. It begins when that app
takes the mic, survives that app's gaps shorter than the drain grace, and ends when that app
has released the mic past the grace. When several apps hold the mic at once, each has its own
session; the sessions overlap in time and share the ring's audio (a session is a per-app
time/byte-range view over the ring, not an owner of bytes).

## Why

The app is the user's recognition handle for recovery: "the Zoom call" is the unit they want
to see, drag, and get back as one file. Union identity made rows ambiguous and merged adjacent
calls in different apps into one row; chop-at-change fragments a 60-min call because a
10-min OBS overlap cut it in three. Per-app concurrent sessions give "Zoom · 60 min" and
"OBS · 10 min" — each row is the whole of that app's use.

## Limitations

- More than one session can be open at a time; the shipped single-open-session model
  (`RecordingSession` open-session state, `OpportunisticCaptureController` identity union)
  must be reworked at design altitude.
- Overlapping sessions dumped separately duplicate the shared audio in their WAVs — by design.
- "App" granularity is the process-identity mapping ProcessAudioMonitor already does
  (bundle IDs → display name, helper-process collapsing); flapping helpers are absorbed by the
  per-app drain grace.

## Reversal

If per-app tracking proves noisy in practice (helper churn creating junk rows) or the rework
cost outgrows its value, fall back to option 1 — unbroken-run sessions with union identity —
which remains the shipped, proven behavior underneath.
