# Capture — device following and self-healing

PURPOSE — which microphone manbok records from, and the guarantees that keep recording
alive and honest through hostile audio events: calls starting/ending in other apps,
devices vanishing or switching, and idle/muted inputs that produce silence.

CONTENTS — Device selection (R1–R3) · Self-healing (R4–R7) · Format (R8) ·
Observability (R9) · Edge cases · Known limitations · Verification.

SCOPE — *which device* and *staying healthy*, from the user's seat. WHEN capture runs at
all: `overview.md` R2 (opportunistic only). Session semantics: `glossary.md` +
`overview.md` R4. Icon/permission surfaces: `popover.md`. Terms: Mic, Session, Ring, PCM
stream per `glossary.md`.

## REQUIREMENTS

### Device selection

- R1 — While a session is open, manbok records from that session's **Mic** — the input
  device its app is actually recording from — not necessarily the system default input.
  When per-app device resolution is unavailable (OS API failure, unrecognizable process),
  capture falls back to the system default input and says so in diagnostics.
  Scenario: Given the system default input is an idle Bluetooth headset and Firefox is
  recording a call through the built-in mic, when the Firefox session is exported, then
  the WAV contains the built-in mic's audio — not silence from the idle headset.
- R2 — When several apps hold the mic through **different** devices, manbok records one
  device: the device shared by the most apps, ties broken by most-recent arrival. The
  not-followed app's session still exists and shares whatever audio the ring receives
  (see L2). Scenario: Given Zoom on a USB mic (arrived first) and QuickTime on the
  built-in mic (arrived later), when both sessions are open, then capture uses the
  built-in mic (most-recent arrival; no shared device) and diagnostics name the choice.
- R3 — When the followed app switches its input device mid-session (e.g., the user picks
  a different mic inside Meet), capture follows within ~5s. The session stays open; the
  ring shows a gap no longer than ~2s. Scenario: Given a Meet session on the built-in
  mic, when the user selects an external mic in Meet's picker, then within ~5s exported
  audio continues from the external mic, same session, one gap ≤2s.

### Self-healing

- R4 — **Stall recovery:** if audio delivery stops while an app still holds the mic (its
  device was removed, a call in another app engaged or ended, the device reconfigured),
  manbok attempts recovery within ~5s. Attempts are rate-limited: at least 1s apart,
  backing off toward one attempt per 30s while attempts keep failing, with an error
  logged from the third consecutive failure. Sessions never close because of a stall.
  Scenario: Given a session recording from a Bluetooth headset, when the headset powers
  off, then within ~5s capture restarts on the newly resolved Mic and the session
  continues with a short gap.
- R5 — **Digital-silence recovery:** if captured audio is digitally silent — every sample
  exactly zero — for 10s continuously while an app holds the mic, manbok re-resolves the
  session's Mic and restarts capture onto it. If the device was already correct, at most
  one further in-place restart is attempted. After 2 consecutive zero-yielding restarts
  on the same device, manbok stops retrying (the input is legitimately muted or idle),
  logs an error once, keeps capturing, and re-arms recovery on the first non-zero sample
  or any device change. Scenario: Given capture mistakenly running against a
  zeros-producing device while Firefox records elsewhere, when 10s of digital silence
  accumulate, then capture restarts on Firefox's actual Mic and subsequent audio is
  non-silent.
- R6 — **Quiet is not silence:** low-but-nonzero audio never triggers recovery. Only
  exact digital zero does — a live, unmuted microphone always carries a noise floor.
  Scenario: Given a session in a silent room for 60 seconds, when logs are inspected,
  then no silence-recovery restart occurred.
- R7 — **No flapping, ever:** recovery attempts never exceed the R4 rate limits
  regardless of trigger mix (stall, silence, device switch); the macOS mic indicator
  never strobes; a device that can never hold capture converges to at most one attempt
  per 30s. Scenario: Given a device that dies immediately on every capture start, when
  10 minutes pass, then attempts are spaced ≥30s apart after the first few and an error
  log names the device.

### Format

- R8 — Everything entering the Ring is the canonical PCM stream (`glossary.md`)
  regardless of the device's native sample rate or channel count, including native-format
  changes mid-session (devices report different channel layouts while calls are active).
  A format change is absorbed with at most a ≤2s gap and no other user-visible effect.
  Scenario: Given a session running while another app's call starts (device flips from
  1 to 3 native channels), when the session is exported, then the WAV is continuous
  mono 16 kHz with at most a ≤2s gap at the transition.

### Observability

- R9 — Every capture start and recovery logs, at notice level, the device identity
  (name + id) and the trigger (arrival, stall, silence, device switch, fallback). The
  silence-recovery hold state (R5) and repeated failures (R4) log at error level. A user
  reading Console (subsystem `ai.manbok.app`) can reconstruct which device every stretch
  of a session came from. Scenario: Given the R1 scenario, when Console is filtered to
  the capture category, then the log names the resolved built-in mic and, if fallback
  ever occurred, names the fallback and its reason.

## STATES — silence-recovery ladder (R5)

| State | Meaning | Leaves when |
|---|---|---|
| **Armed** | Normal capture; silence clock runs whenever samples are exactly zero, resets on any non-zero sample. | 10s of continuous digital silence → **Re-resolving**. |
| **Re-resolving** | Mic re-resolved; capture restarted onto the resolved device (rate limits of R4 apply). | Non-zero audio → **Armed**. Still zero AND device unchanged → **Retrying**. Still zero AND device changed → stay (fresh resolution, counts reset). |
| **Retrying** | One in-place restart on the same device. | Non-zero audio → **Armed**. Zero again (2nd zero-yielding restart, same device) → **Holding**. |
| **Holding** | Input treated as legitimately muted/idle: capture continues, no further restarts, one error logged on entry. | First non-zero sample, any device change, or session demand change → **Armed**. |

## EDGE CASES

- E1 — Mic permission revoked mid-session: recovery attempts fail; the permission
  surfaces take over (`popover.md` R2/R15); on re-grant, capture resumes without app
  restart (existing behavior, unchanged).
- E2 — Per-app device resolution unavailable for the followed app: fallback to system
  default (R1), logged; the digital-silence guard (R5) is the safety net when the
  fallback records a zeros-producing device.
- E3 — The followed app holds multiple input devices simultaneously: treated as R2
  ambiguity — the shared/most-recent rule applies across devices.

## KNOWN LIMITATIONS

- L1 — While any app's call uses macOS voice processing, ALL captured audio is
  substantially quieter (~18–20 dB) — an OS behavior, present regardless of device or
  design. Recordings during calls are quiet, never silent.
- L2 — One device at a time (R2): when concurrent apps use different mics, only the
  chosen device's audio is real for its session; the other session's view shows the
  same (wrong-device) audio. Accepted per docs/decisions/20260707-capture-follows-app-mic.md.
- L3 — Device transitions cost a 0.3–2s gap; sessions are continuous, audio has holes.
- L4 — A hardware-muted input records digital silence; manbok cannot conjure signal — it
  stops flapping and flags (R5) instead.

## VERIFICATION

Manual runsheet (needs a BT headset + a WebRTC call):
P1 pinned capture stable 60s while the default input points elsewhere.
P2 default input churn mid-run does not interrupt capture.
P3 pinned device removed mid-run → recovery per R4, visible in logs.
P4 idle BT headset as default + plain default-follow capture → digital zeros observed
   (the incident, reproduced); then R5 behavior with the product build.
P5 same idle-BT state, per-app following active → R1 scenario passes.
Plus: a real Meet/Zoom call in Firefox across start AND end (R4/R8), a silent-room hour
(R6), Console reconstruction of a multi-device session (R9).
