# manbok glossary

PURPOSE — the product's ontology. Every spec, design doc, and conversation speaks these nouns
and verbs. Evolving a term requires a decision record in `docs/decisions/`; silent drift is
forbidden.

Graduated 2026-07-05 from the menubar-app cycle (gated 2026-07-04) as the product's first
standalone glossary; baseline audio nouns folded in from ARCHITECTURE.md §1.

SCOPE — definitional authority, not a behavioral spec: no REQUIREMENTS/VERIFICATION sections
apply here. Behavior lives in the surface specs (`overview.md`, `popover.md`, `settings.md`,
`lifecycle.md`, `interfaces/ipc.md`), all of which speak these terms.

## Identity

**manbok is a rolling audio memory that lives in the menu bar.** While any other app uses the
microphone, manbok silently keeps a copy of the most recent stretch of what was said, holds it
only in RAM, and lets the user see it — session by session — and grab any piece as a WAV file.

What it is NOT (nearest wrong framings):

- **Not a voice recorder.** It never initiates mic use, never decides to record, and never
  writes audio to disk on its own. Recording apps make files; manbok makes *recovery possible*.
- **Not a mic-usage monitor.** Detecting which app holds the mic is how sessions get their
  identity, not a surveillance feature of the product.
- **Not a terminal daemon with a UI bolted on.** The menu bar app IS the product and IS the
  long-lived process; the CLI is a convenience client of it.

## Nouns

| Noun | Meaning |
|---|---|
| **App** (the manbok app) | The single long-lived menu-bar process. Owns capture, the ring, sessions, and the IPC socket. There is no separate daemon. |
| **Ring** | The in-RAM store of the most recent PCM audio, sized by *Buffer duration*. When full, the newest audio silently replaces the oldest. |
| **Buffer duration** | The user-chosen length of audio the ring can hold — a preset number of minutes (5/10/30/60/120, default 10). Its RAM cost (~1.9 MB/min) is part of the concept: shown wherever the choice is made. |
| **Session** | **One app's unbroken use of the microphone.** Begins when that app takes the mic (first audio lands in the ring), survives that app's gaps shorter than the drain grace, ends once that app has released the mic past the grace. Several sessions may be *open* at once — one per app — overlapping in time and sharing the ring's audio: a session is a per-app view over the ring, not an owner of bytes. A session exists only while its audio is in the ring. |
| **App identity** (of a session) | The single app a session belongs to, shown as a short, recognizable display name ("Zoom", not "us.zoom.xos" or "zoom.us Helper"). One app per session, always. Granularity is the app, never the content inside it: a Meet call in Chrome is "Chrome" — the OS exposes nothing finer. |
| **Waveform** | A session's static amplitude thumbnail, fixed when the session closes (growing while open). Not live-editable — a recognition aid. |
| **Dump** | Exporting audio from the ring to a WAV file — the only path from RAM to disk. A dump targets a session (the normal case) or a raw span of the ring (whole ring / last N minutes, CLI only). In the popover it appears as two gestures over the same operation: the Dump button and Copy. *(Drag-out deferred: docs/decisions/20260705-defer-drag-out.md.)* |
| **Settings** | Exactly two user choices: *Buffer duration* and *Start at login*. Nothing else is configurable. |
| **Popover** | The primary working surface: opened from the menu bar icon, showing state, ring fill, and the session list. The standard Settings window and About panel are the only other app surfaces. |
| **CLI** | `manbok` in a terminal — a thin client. `status`/`dump`/`stop` talk to the App over the Unix socket; `start` means "open the App". |
| **PCM stream** | The canonical in-RAM audio: mono 16 kHz 16-bit little-endian samples (~1.9 MB/min). Everything the ring holds is this format, regardless of the mic's native format. |
| **WAV** | The export container: the dumped PCM span wrapped in a standard WAV header. The only file format manbok produces. |
| **Mic** | The system default input device, as held by *other* apps. manbok taps it only while at least one other app holds it. |

**Retired vocabulary:** *Listener/Daemon* as a distinct noun (absorbed into App); *always-on
capture* (dropped — opportunistic capture is the product; reversal recorded in
docs/decisions/20260704-menubar-app-process-model.md); *LaunchAgent* (replaced by the
Start-at-login setting; migration removes any installed plist).

## Verbs

| Verb | Meaning |
|---|---|
| **watch** | The App idles, checking whether any other app is using the mic. No capture. |
| **record** | The App captures mic audio into the ring while other app(s) hold the mic. **The user-visible Recording state means "any session is open"** — a session in its drain grace is still open, so Recording persists through drain and ends only when the last session closes. |
| **drain** | The per-app grace window after an app releases the mic, before its session closes — a quick reclaim by the same app continues that session. Drain is an invisible debounce, **never a user-facing state**: no surface names it or renders it distinctly. |
| **open / close** (session) | A session opens with its app's first captured audio and closes after that app's drain. Closing fixes its times and waveform. |
| **expire** (session) | A closed session vanishes **as a whole** the moment its beginning is overwritten — by ring wrap or by a shrink-resize. The *open* session instead shrinks from the front, keeping its newest audio. |
| **resize** (ring) | Changing Buffer duration takes effect immediately, preserving the newest audio that fits. Closed sessions that no longer fit expire per the rule above. |
| **dump / copy** | Export a session as a WAV file: to the temp directory (revealed in Finder), or to the clipboard as a file URL. |
| **start at login** | The App registers itself as a macOS login item; toggled in Settings. |
| **quit** | The App exits: capture ends, the ring and every session vanish (RAM-only by design), the socket closes. Reachable from the Popover footer; CLI `stop` performs the same quit remotely. |

## Icon states (glance vocabulary)

The menu bar icon has **two states** — Watching (ear, template gray) and Recording (ear +
sound waves, red) — driven by the one any-session-open signal. The mic-permission warning
slash is a **failure overlay on Watching**, not a third state: it marks "cannot watch," and
disappears when permission returns.

## Boundaries — categorical

1. **manbok never initiates mic use.** It records only while another app holds the mic.
   Opportunistic capture is not a mode; it is the product.
2. **No audio reaches disk except by explicit user export.** Dump (either GUI gesture, or via
   CLI) is the only door.
3. **Sessions have no existence outside the ring.** No persistence, no history, no database.
   A session's lifetime is exactly the *expire* rule above: a closed session vanishes whole
   once its beginning is overwritten (even if later bytes linger until overwritten in turn);
   the open session shrinks from the front.
4. **Editing is outside the product.** The GUI hands the user a file and stops; it never opens
   Audacity or any editor (that remains a CLI habit only).
5. **The vocabulary is platform-free.** No concept on this page is defined by UI, clipboard,
   or OS-integration machinery — session, waveform, and resize are *concepts*; how macOS is
   wired to them lives at the product's edges.
