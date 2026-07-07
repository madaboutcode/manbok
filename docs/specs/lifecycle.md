# App lifecycle

PURPOSE — launch, first-run permission, single-instance behavior, quit, and the one-time
LaunchAgent migration.

CONTENTS — Permission & launch (R1) · Single instance & socket (R2–R3) · Migration (R4–R5) ·
Start & quit (R6–R7) · Edge cases · Verification.

SCOPE — the App as a process, from the user's seat. Icon/popover behavior: `popover.md`.
Wire protocol: `interfaces/ipc.md`.

## REQUIREMENTS

- R1 — The mic-permission ask happens at **first launch**, not lazily at first capture —
  the OS dialog fires at an intentional moment, never mid-meeting. The dialog itself is
  OS-owned. Denied ⇒ `popover.md` R2/R15 states; granted-later recovery is automatic.
- R2 — The App is a single instance. Opening manbok.app while it runs activates the existing
  instance (shows the popover) — never a second process, never a socket fight.
- R3 — On launch, the App claims the existing socket path and serves the CLI (`manbok
  status`/`dump`/`stop` work against it; `interfaces/ipc.md`).
- R4 — **Migration:** if a manbok LaunchAgent from the CLI-era install exists, first App
  launch unloads and removes it, so exactly one manbok process can ever own the socket.
  Observable: after launching the App once, `launchctl list` shows no manbok entry and the
  LaunchAgents plist is gone. Stale socket/pid files from a dead process are cleaned the
  same way.
- R5 — The Start at login toggle (`settings.md` R6) is the single source of truth for
  login-time presence; no LaunchAgent is ever (re)installed.
- R6 — `manbok start` behavior per `overview.md` R8; a CLI-triggered launch is a normal
  launch (R1–R4 all apply).
- R7 — **Quit** (popover footer, or CLI `stop`): immediate — capture ends, the ring and
  sessions are checkpointed to `~/.manbok/` for restore at next launch, socket closes,
  process exits. No confirmation dialog; the glossary's quit semantics are the contract.

## EDGE CASES

- E1 — App launched while an old CLI-era daemon still runs and holds the socket: migration
  (R4) stops it; the App ends up the sole owner. At no point do two processes capture
  simultaneously.
- E2 — Quit while a session is open: no export, no prompt — the ring and sessions ride the
  checkpoint (R7) and are back after relaunch. Export is still the only way to a WAV.

## VERIFICATION

Fresh install: launch → permission dialog appears immediately; deny → overlay state; grant
in System Settings → recovers unaided. Install the old LaunchAgent, launch the App, verify
`launchctl list | grep manbok` is empty and the plist is deleted. Double-launch the app and
count processes. Quit mid-recording and verify `manbok status` refuses connection and no
file was written.
