# upil-appa Menu Bar App — Functional Spec

**Status:** Draft  
**Date:** 2026-06-05  
**Mockup:** `mockups/menu-bar-app.html`

---

## 1. What This Is

Convert upil-appa from a CLI daemon to a native macOS menu bar app. The app becomes the process that owns the ring buffer and audio capture. CLI access is preserved via Unix socket IPC.

## 2. Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Architecture | App *is* the daemon (Option A) | Cleaner than two separate processes. Core library is already framework-free — drops into SwiftUI app unchanged. |
| Capture mode | Opportunistic (default) | Watches for other apps using the mic, piggybacks. No orange mic dot when idle. Matches current CLI behavior. |
| UI surface | Popover attached to menu bar icon | Like AirDrop/WiFi panels. Dismisses on click-away. Native macOS vibrancy. |
| Session scope | Only sessions currently in ring | No persistence. When ring wraps and overwrites a session's start, it disappears from the list. |
| Post-dump behavior | No auto-open | GUI provides copy/drag — user decides what to do with the file. |
| Settings | None in v1 | Hardcoded defaults. Add settings later if needed. |
| Copy to clipboard | File reference (NSPasteboard file URL) | Paste into Finder, Audacity, Slack, etc. Same as copying a file in Finder. |
| Drag behavior | Lazy dump on drag start | NSFilePromiseProvider creates temp WAV when drag begins. Slight delay, but no wasted disk for undragged sessions. |
| Waveform | Static miniature per session | Pre-rendered ~100 amplitude peaks. Computed on session finalize, not live. |
| Visual style | Native macOS | System materials, vibrancy, standard controls. Blends with OS. |
| CLI preserved | Yes, via IPC | CLI becomes a thin client. `dump`, `status`, `stop` talk to the app process over Unix socket. |

## 3. Menu Bar Icon

Static mic icon. Color reflects state:

| State | Icon Color | Extra |
|-------|-----------|-------|
| Watching (no mic activity) | Gray (#888) | — |
| Recording (mic active) | Red (#ff453a) | — |
| Watching + undumped sessions in ring | Gray + blue dot | Small #64d2ff dot, top-right corner |

Icon does not animate. macOS already shows the orange mic-in-use indicator — we don't need to duplicate that signal with animation.

## 4. Popover Layout

### Header
- App icon (mic, colored by state)
- App name: "upil-appa"
- Status badge: "Watching" (amber) or "Recording" (red, pulsing dot)
- Ring fill indicator: "4:32 / 10:00" or "Ring empty"

### Session List
Scrollable list (max height ~380px). Each row contains:

- **App icon** — colored square with app's icon/symbol (Zoom blue, Meet teal, Teams purple, etc.)
- **App name** — which app triggered the session (from ProcessAudioMonitor)
- **Time info** — start time for completed sessions; duration for active session
- **Mini waveform** — ~260px wide, 24px tall bar chart of amplitude peaks
  - Active session: red gradient, growing rightward
  - Completed session: blue gradient, full width

#### Active Session
- Highlighted row background (subtle red tint)
- App name suffixed with " · Recording"
- Duration counts up live

#### Session Row Actions (visible on hover)
Two buttons, right-aligned:

1. **Dump** (download icon) — writes WAV to temp dir, shows path in some feedback
2. **Copy file** (clipboard icon) — dumps to temp, puts file URL on NSPasteboard

#### Drag-as-File
The entire session row is a drag source. On drag start:
1. Lazy-dump the session's PCM range to a temp WAV
2. Provide via NSFilePromiseProvider
3. Show a drag ghost: file icon + filename (e.g., `meet-session-1352.wav`)

### Footer
- "About" button (left)
- "Quit" button (right, red-tinted)

### Empty State
When ring has no sessions:
- Large muted mic icon
- "No sessions in ring"
- "Audio will appear when an app uses the microphone"

## 5. State Machine

```
Launch → Watching
Watching → Recording    (ProcessAudioMonitor detects mic acquisition)
Recording → Draining    (mic released by other app)
Recording → Watching    (short burst below threshold — discard)
Draining → Watching     (silence timeout — session finalized to ring)
```

Session finalization creates a session entry: `{ app, startTime, duration, ringRange, waveformPeaks }`.

Sessions exist only while their PCM data is in the ring buffer.

## 6. Architecture Changes

### New SPM Target
```
UpilAppaApp (SwiftUI executable, .app bundle)
  ├── depends on UpilAppaCore
  └── depends on UpilAppaPlatform
```

### What Stays
- `UpilAppaCore` — unchanged. Domain types, ring buffer, WAV encoder, IPC types.
- `UpilAppaPlatform` — capture, IPC server, file I/O, logging all reused.
- Unix socket IPC at `~/.upil-appa/run.sock`
- PID file at `~/.upil-appa/appa.pid`

### What Changes
- **Process model:** `NSApplication` with `LSUIElement = true` replaces daemon fork. App *is* the long-lived process.
- **Entry point:** SwiftUI `@main App` with `MenuBarExtra` instead of `DaemonMain`.
- **ListenerService** runs inside the app process, not a detached daemon.
- **CLI target** (`upil-appa`) becomes client-only — strips daemon logic, keeps IPC client commands.
- **TerminalCaptureMeter** — no longer needed (or optional, for a `--foreground` debug mode).

### New Components
| Component | Layer | Responsibility |
|-----------|-------|---------------|
| `UpilAppaApp` (SwiftUI) | L4 | App lifecycle, MenuBarExtra, popover |
| `SessionListView` | L4 | SwiftUI list of ring sessions |
| `SessionRowView` | L4 | Individual session: icon, meta, waveform, actions |
| `WaveformView` | L4 | Canvas/Path rendering of amplitude peaks |
| `MenuBarIconManager` | L4 | Updates icon color/badge based on state |
| `DragFileProvider` | L4/Platform | NSFilePromiseProvider wrapper for lazy dump |
| `PasteboardService` | Platform | Writes dumped WAV file URL to NSPasteboard |
| `WaveformSampler` | Core | Downsamples PCM ring range to N amplitude peaks |

## 7. IPC Contract (unchanged)

```
CLI → App (Unix socket):
  PING          → PONG
  STATUS        → LISTENING | STOPPED | WATCHING
  DUMP [minutes] → OK path=/tmp/upil-appa-*.wav | ERR <message>
  STOP          → OK
```

The app process runs the IPC server. CLI sends commands as before.

## 8. Dump Flow

All three UI actions (dump button, copy, drag) share the same underlying operation:

1. Identify session's byte range in ring buffer
2. Extract PCM from ring
3. Write WAV header + PCM to temp file (`$TMPDIR/upil-appa-YYYYMMDD-HHMMSS.wav`)
4. Return file path

Then:
- **Dump button:** show brief confirmation (path or checkmark feedback)
- **Copy:** put file URL on NSPasteboard
- **Drag:** provide path to NSFilePromiseProvider

Active sessions can also be dumped — snapshot of ring content up to current write position.

## 9. Waveform Generation

On session finalize:
1. Read session's PCM range from ring (16-bit signed, mono, 16 kHz)
2. Divide into N buckets (~100 for the row width)
3. For each bucket: compute max absolute amplitude
4. Normalize to 0.0–1.0
5. Store as `[Float]` on the session model

Render as vertical bars in SwiftUI Canvas. Color:
- Active session: red gradient (left=0.6 opacity, right=0.2)
- Completed session: blue gradient (#64d2ff, left=0.5, right=0.15)

## 10. App Lifecycle

- **Launch at login:** Via `SMAppService.mainApp` (macOS 13+). Not configurable in v1 — user enables via System Settings > Login Items or we add a toggle later.
- **Quit:** From popover footer. Stops capture, closes IPC socket, removes PID file.
- **Mic permission:** First capture triggers macOS mic permission dialog. Same as current CLI behavior.

## 11. Open Questions

1. **Filename convention for dumps:** Currently `upil-appa-YYYYMMDD-HHMMSS.wav`. Should GUI dumps include app name? e.g., `zoom-20260605-143422.wav`
2. **Feedback on dump:** Brief toast/animation in popover? Or just trust the action completed?
3. **Accessibility:** VoiceOver labels for waveform, drag source, session actions.
4. **Distribution:** Direct .app download? Homebrew cask? (Affects code signing, notarization.)
