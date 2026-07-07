# manbok — product overview

PURPOSE — what manbok is, its invariants, its surfaces, and the CLI touchpoints; the parent
spec that the surface specs decompose.

CONTENTS — What the product is · Requirements · CLI touchpoints · Verification.

SCOPE — identity and cross-cutting rules live here. Popover/icon behavior: `popover.md`.
Settings: `settings.md`. Process lifecycle: `lifecycle.md`. Wire protocol: `interfaces/ipc.md`.
Ontology: `glossary.md` (authoritative for every term used here).

## What the product is

A rolling audio memory in the macOS menu bar. While any other app uses the microphone, the
App keeps the most recent stretch of audio in an in-memory Ring, organized into per-app
Sessions, and lets the user export any Session as a WAV — from the popover or the CLI —
without manbok ever initiating mic use. The only disk artifacts are user exports and the
quit Checkpoint (restored, then removed, at next launch).

## REQUIREMENTS

- R1 — The App is a menu bar utility: a status-bar icon with a popover, a standard Settings
  window, and a standard About panel. It has no Dock icon and no main window.
- R2 — Capture is opportunistic only: audio enters the Ring exactly while at least one other
  app holds the mic. manbok never initiates mic use (glossary boundary 1).
- R3 — During capture, audio reaches disk only by explicit user export (Dump/Copy in the
  popover; `dump` in the CLI). On quit the Ring and Sessions are checkpointed to
  `~/.manbok/`, then restored and the checkpoint deleted at next launch — a restart loses
  nothing; deleting `~/.manbok/` while quit erases everything (glossary boundary 3).
- R4 — Sessions are per-app: one open session per app, several open concurrently when apps
  overlap on the mic; each is a view over the shared Ring's audio. Overlapping sessions
  exported separately each contain the full shared audio (by design).
- R5 — The Ring's capacity is the user's Buffer duration choice (5/10/30/60/120 min presets,
  default 10). Ring full ⇒ newest audio silently replaces oldest; sessions expire per the
  glossary's expire rule.
- R6 — One signal drives every state surface: *is any session open?* Icon color, header
  badge, and row treatments may never disagree; a session in drain grace counts as open.
  The signal derives from `SESSIONS` open-count (`open:1`), NOT from `STATUS` `phase` —
  `phase` is a daemon-global capture state that reads `"watching"` during drain even while
  sessions are still open.

## CLI touchpoints

The CLI is a thin client of the App over the existing Unix socket (`interfaces/ipc.md` is
the authoritative wire spec; these are the user-observable behaviors):

- R7 — `manbok status`, `manbok dump [minutes]`, `manbok stop` work unchanged against the
  App: same stdout the user has today (`stop` quits the App — identical to popover Quit).
- R8 — `manbok start`: if the App is running, prints `manbok is already running` and exits 0;
  otherwise launches the .app and exits.
- R9 — Any other command while the App is not running fails with the hint:
  `manbok isn't running — run 'manbok start' or open manbok.app`.
- R10 — Raw-span CLI dumps (whole ring / last N minutes) are named
  `manbok-YYYYMMDD-HHMMSS.wav`; they have no app identity. Session dumps follow
  `popover.md` R12 naming.

## VERIFICATION

Run another app against the mic; observe icon/popover per `popover.md`; export via each
gesture and via CLI; quit and confirm `manbok status` reports the App gone and no audio file
exists that the user didn't explicitly export.
