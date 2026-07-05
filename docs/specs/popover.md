# Menu bar icon + popover

PURPOSE — the glance surface (icon) and the primary working surface (popover): states,
session list, export gestures, and their failure behavior.

CONTENTS — Icon · Popover layout · Session rows · Export gestures · Empty state ·
Permission state · Accessibility · Edge cases · Verification.

SCOPE — Settings window: `settings.md`. Launch/quit/migration: `lifecycle.md`. Terms:
`glossary.md`. Supersedes `docs/menu-bar-app-spec.md` §3–5 (June-5 draft).

## Icon (glance)

- R1 — Two states, driven by the one any-session-open signal (overview R6):
  **Watching** = ear glyph, template gray; **Recording** = ear + sound waves, red. Shape AND
  color change (readable color-blind). No animation, no badges, no other states.
- R2 — Mic permission denied/revoked ⇒ the Watching ear gains a small warning slash — a
  failure overlay, removed automatically when permission returns (see R15).
- R3 — Clicking the icon opens the popover; click-away dismisses it.

## Popover layout

One column, three zones:

- R4 — **Header:** app name; state badge "Watching" (secondary gray) or "Recording" (red with
  pulsing dot; dot static under Reduce Motion). Ring fill bar with `held / capacity` in
  minutes (e.g. "7:12 / 30:00"); reads "Ring empty" when the ring holds nothing.
  Watching is never amber — amber is reserved for the warning badge (R16).
- R5 — **Session list:** sessions newest-start-first (open sessions therefore at/near top);
  scrolls past ~5 rows.
- R6 — **Footer:** About (left) · Settings… (middle) · Quit (right, red-tinted text) — plain
  text items, hover color shift only. About opens the standard about panel (name, version,
  "rolling audio memory in your menu bar"). Quit per `lifecycle.md` R7.

## Session rows

- R7 — Each row shows: app display name (App identity, per glossary), clock range, duration,
  waveform. Open row: red treatment, "· Recording" text, open-ended range ("2:32 PM –"),
  waveform grows (discrete ~1 Hz under Reduce Motion — and growth is periodic refresh, not
  continuous animation, in any case). Closed row: muted-blue full-width waveform, closed
  range ("2:10–2:28 PM").
- R8 — Time format: line 1 = clock range respecting the system 12/24-hour setting; line 2 =
  duration, always m:ss ("18:22", "0:41"). The duration slot never reads as a clock time.
- R9 — Concurrent sessions render nothing special: self-contained rows, sorted by start time;
  overlap is visible only by comparing time labels.
- R10 — Hover AND keyboard focus reveal two right-aligned icon buttons — **Dump** (⬇) and
  **Copy** (⧉) — 28×24 pt, 6 pt gap. Visually hidden otherwise but ALWAYS present in layout,
  tab order, and the accessibility tree (never unrendered).

## Export gestures

Both gestures export the session's audio (an open session exports everything captured so
far) as a WAV per R12 naming. *(Drag-out deferred: docs/decisions/20260705-defer-drag-out.md.)*

- R11 — **Dump:** writes the WAV to the temp directory and reveals it in Finder. The Finder
  window is the feedback — no toast, no dialog.
  **Copy:** writes the WAV to the temp directory and puts the file URL on the clipboard; the
  button swaps to a checkmark + "Copied" for ~1.5 s on its own timer, independent of hover.
- R12 — Session dump filename: `manbok-<slug>-YYYYMMDD-HHMMSS.wav` — slug = lowercased app
  display name (alphanumeric + hyphen), timestamp = **session start**. Example:
  `manbok-zoom-20260704-143205.wav`. Name collisions never overwrite: `-2`, `-3`… suffix.
- R13 — The popover stays open through an export gesture (dismisses on click-away as normal).

## Empty state

- R14 — Ring empty ⇒ list area shows: muted ear glyph, "No sessions in the ring", "Audio
  appears here when another app uses the microphone." Header still shows Watching + "Ring
  empty"; footer unchanged.

## Permission state

- R15 — Mic permission denied/revoked ⇒ header badge "Mic access needed" (warning tint);
  the body swaps to a single message — "manbok needs microphone access to keep audio." with
  an "Open System Settings…" button deep-linking to Privacy & Security → Microphone; footer
  unchanged. Once granted, the App returns to Watching on its own — no relaunch.

## Accessibility

- R16 — A session row is one VoiceOver element: label "Zoom, 2:10 to 2:28 PM, 18 minutes"
  (+ ", recording" when open); waveform is decorative (hidden from accessibility). Row
  actions are VO custom actions: "Dump WAV file", "Copy WAV file".
- R17 — Keyboard: list is arrow-navigable with a visible focus ring; ⏎ = dump, ⌘C = copy on
  the focused row.
- R18 — Color is never the sole state carrier (shape+color icon, tint+text rows, text
  badges); text contrast ≥ 4.5:1 including times over vibrancy.
- R19 — Errors are announced to VoiceOver when shown (E1's inline message, R15's panel), not
  just drawn.

## EDGE CASES

- E1 — Export failure (temp dir unwritable, encode error): the row's action area shows an
  inline "Couldn't export" message for a few seconds; the buttons are visually suppressed
  while it shows (never stacked with it) but remain in tab order and the accessibility tree.
  The row stays.
- E2 — Session expired between hover and click (ring overwrote its start): the gesture
  quietly does nothing — no export, no wrong bytes — and the row disappears as the list
  re-renders.
- E3 — Dumping the same still-open session twice yields the same start-time name ⇒ second
  export gets the `-2` suffix (R12).

## VERIFICATION

Drive a real mic-holding app: watch icon flip gray→red at first audio and back after the
last session's drain; confirm one-signal consistency (icon vs badge vs rows) through the
drain window; export via each gesture including from an open session; force E1 (read-only
temp override) and E2 (small ring, wait for wrap); walk the list with VoiceOver and
keyboard only.
