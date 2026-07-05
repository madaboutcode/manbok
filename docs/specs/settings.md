# Settings window

PURPOSE — the two user choices (Buffer duration, Start at login), how they apply, and how
they fail.

CONTENTS — Buffer duration (R1–R5) · Start at login (R6–R7) · Edge cases · Verification.

SCOPE — opened from the popover footer (`popover.md` R6) or ⌘,. Standard macOS settings
window — the popover dismisses when it opens. Nothing else is configurable (glossary:
Settings). Login-item *migration* mechanics: `lifecycle.md`.

## REQUIREMENTS

- R1 — **Buffer duration** is a radio group of exactly five presets: 5, 10 (default), 30,
  60, 120 minutes. No custom values.
- R2 — Each preset shows its RAM cost beside it (~1.9 MB/min: "~10 MB", "~19 MB", "~58 MB",
  "~115 MB", "~230 MB") — visible before choosing, not after.
- R3 — Any preset smaller than what the ring currently holds carries a live annotation of
  the consequence — "removes N sessions" — computed from the current session list at the
  moment of display. Text only; no dialog.
- R4 — Selection applies immediately: no Save, no confirmation. Resize preserves the newest
  audio that fits; closed sessions whose beginning no longer fits expire whole (glossary:
  resize/expire). The caption states the consequence up front: "Kept in memory only.
  Shrinking discards the oldest audio immediately."
- R5 — The consequence surfaces where the user already looks: reopening the popover shows
  the new capacity in the ring-fill bar; expired sessions are simply gone.
- R6 — **Start at login** is a single checkbox, applying immediately via macOS login-item
  registration. macOS's own "added as login item" notification may appear — OS-owned.
- R7 — The Buffer duration choice persists across App relaunches; Start at login reflects
  the actual registration state.

## EDGE CASES

- E1 — Resize cannot allocate (e.g. 230 MB refused): the selection reverts and an inline
  message under the group reads "Couldn't resize — kept N min." No dialog.
- E2 — Login-item registration fails or is blocked: the checkbox reverts with the inline
  message "macOS declined — check System Settings → Login Items."

## VERIFICATION

Shrink below current fill with 3+ sessions listed: annotation predicts the loss, popover
confirms it after; grow and confirm no sessions lost; relaunch and confirm the preset stuck;
toggle login item on/off and confirm presence/absence in System Settings → Login Items and
across a reboot.
