<p align="center">
  <img src="docs/images/logo.png" width="160" alt="manbok — an amber ear inside glowing rings">
</p>

# manbok

**A rewind button for your Mac's microphone.**

[![CI](https://github.com/madaboutcode/manbok/actions/workflows/ci.yml/badge.svg)](https://github.com/madaboutcode/manbok/actions/workflows/ci.yml)

<p align="center">
  <img src="docs/images/popover-sessions.png" width="360" alt="manbok popover: per-app sessions with waveforms, a live Zoom session recording, and the tape gauge showing 7:12 of 30:00">
</p>

These days you talk to your computer as much as you type at it: voice mode with ChatGPT, dictation for anything longer than a sentence.

You speak your plan for the day into ChatGPT's voice mode. It listens, shows a spinner, then: *"Oh, something went wrong!"* Ten minutes of talking, gone.

You dictate a long technical note and the transcript butchers half the jargon. Heard Gemini's new model handles these better. Oops, should you say all that again?

You hop on an impromptu Slack call to walk a teammate through the design: every edge case, every gotcha. That walkthrough was basically a Jira ticket with acceptance criteria. If only it were written down somewhere.

Sounds familiar?

So, manbok: a little menu bar app that keeps everything any app recorded from your mic, up to the last two hours of it (configurable), in RAM. Open the popover, hit Dump, and the audio is back as a WAV: replay it, or hand it to a different transcriber and skip the retake. No WAV is written until you ask, and nothing ever leaves your machine.

There's nothing to babysit, either. It's a ring buffer: new audio overwrites the oldest, so nothing accumulates, and capture never touches the disk. It uses a fixed chunk of RAM and that's it. Set it up once and forget it's running.

The name? [**Jung Man-bok**](https://en.wikipedia.org/wiki/Crash_Landing_on_You#People_in_the_North_Korean_Forces) (정만복), the wiretapper in [*Crash Landing on You*](https://en.wikipedia.org/wiki/Crash_Landing_on_You): always listening, never missing a word.

## Install

```bash
git clone https://github.com/madaboutcode/manbok.git
cd manbok
make install-app            # build + assemble → ~/Applications/Manbok.app
open ~/Applications/Manbok.app
```

You need macOS 14+ (Sonoma) on Apple Silicon, with the Xcode Command Line Tools
(`xcode-select --install`).

The ear icon appears in your menu bar. Approve the microphone prompt on first launch,
and if you want manbok there every login: popover → Settings → "Start at login." Done.

<details>
<summary>Prefer a prebuilt download?</summary>

Grab `Manbok-<version>-macos-arm64.zip` from [Releases](https://github.com/madaboutcode/manbok/releases) and unzip into `~/Applications`. The app isn't notarized yet, so macOS warns on first open: right-click → **Open**, or **System Settings → Privacy & Security → Open Anyway**. Building from source avoids the warning entirely.
</details>

### Uninstall

Quit the app (popover → Quit), then `rm -rf ~/Applications/Manbok.app`.

## User guide

### The menu bar icon

| Icon | Meaning |
|------|---------|
| Ear (gray) | **Watching** — no app is using the mic |
| Ear + waves (red) | **Recording** — at least one app is using the mic |
| Ear + slash | **Mic access needed** — permission denied or revoked |

Click the icon to open the popover.

<p align="center">
  <img src="docs/images/popover-empty.png" width="300" alt="Empty state: Listening…"
  >&nbsp;<img src="docs/images/popover-noaccess.png" width="300" alt="Permission denied state: Mic access needed">
</p>

### The popover

- **Header:** state badge + ring fill (e.g. "7:12 / 30:00")
- **Session list:** one row per app that used the mic, newest first. Each row shows the app name, time range, duration, and a waveform.
- **Export:** hover or focus a row to reveal **Dump** (saves WAV, reveals in Finder) and **Copy** (WAV to clipboard). Keyboard: arrows to navigate, Return = dump, Cmd+C = copy.
- **Footer:** About · Settings · Quit

### Settings

- **Buffer duration:** 5 / 10 (default) / 30 / 60 / 120 minutes. RAM cost shown beside each. Applies immediately — shrinking discards the oldest audio.
- **Start at login:** registers the app as a login item via macOS.

### The CLI (optional)

Everything above works without a terminal. If you script things, a thin CLI client talks to the running app over a Unix socket:

```bash
make install                # → ~/.local/bin/manbok  (make uninstall removes it)
```

| Command | Description |
|---------|-------------|
| `manbok start` | Open Manbok.app (prints "already running" if it is) |
| `manbok stop` | Quit the app |
| `manbok status` | Phase + ring fill |
| `manbok sessions` | List sessions (stable ids, per-app) |
| `manbok dump` | Export newest session → WAV path on stdout |
| `manbok dump 1` | Export by stable session id (`-1` = previous session) |
| `manbok dump all` | Full ring (no session framing) |
| `manbok dump --minutes 5` | Last N minutes of ring |

State: `~/.manbok/` (pid + Unix socket). Logs: Console.app, subsystem `ai.manbok.app`. Debug modes (foreground daemon with a terminal meter): see `make help`.

## How it works

```
CLI (short-lived) ──IPC──► App (long-lived) ──► CaptureOrchestrator ──► AVAudioEngine ──► ring buffer
                              ├── PopoverViewModel ──► SwiftUI views
                              └── dump ──► temp WAV ──► Finder / clipboard
```

- **Audio:** mono 16 kHz, 16-bit PCM (~32 KB/s). Ring overwrites oldest data when full.
- **Opportunistic capture:** manbok never initiates mic use. Audio enters the ring only while another app holds the mic.
- **Microphone only:** manbok hears what your mic hears: your voice. On a call, the other side comes through your speakers and is not captured. What you said is saved; what you heard is not.
- **Per-app sessions:** each app that uses the mic gets its own session with a stable id. Overlapping sessions share the same audio (by design — they're views over one ring).
- **Disk:** capture is RAM-only; WAVs are written only when you export. On quit, the ring is checkpointed to `~/.manbok/` so a restart doesn't lose it — reloaded and deleted on next launch.

## Development

```bash
make verify                 # test + build — run this before a PR
make run-app                # build + open the app
```

Everything else: `make help`. Contribution guidelines: [CONTRIBUTING.md](CONTRIBUTING.md).

### Project structure

| Module | What it owns |
|--------|-------------|
| `Sources/ManbokCore/` | Domain: ring buffer, sessions, waveform, IPC types. No frameworks. |
| `Sources/ManbokPlatform/` | macOS adapters: AVAudioEngine, sockets, files, settings, migration |
| `Sources/ManbokApp/` | SwiftUI app: MenuBarExtra, popover, settings window |
| `Sources/manbok/` | CLI: ArgumentParser subcommands, thin IPC client |

Each module has a `CLAUDE.md` with a jumpstart and layout table. Architecture: `ARCHITECTURE.md`.

## Privacy

manbok is an always-on microphone buffer, so here is exactly what it does with audio:

- **Capture is opportunistic.** manbok never opens the microphone on its own. Audio enters the buffer only while *another* app is actively using the mic.
- **RAM while running.** Audio lives in a fixed-size ring buffer in memory (5–120 minutes, your setting). Nothing is written to disk during capture.
- **Export is explicit.** A WAV file is created only when you click Dump/Copy or run `manbok dump`. Files go to the system temp directory (or your clipboard) — you decide where they end up after that.
- **Quit keeps your buffer.** On quit, the ring is checkpointed to `~/.manbok/` in your home folder, and reloaded — then deleted — on next launch, so a restart doesn't cost you your audio.
- **Nothing leaves your machine.** There is no network code in this app. No telemetry, no analytics, no accounts.
- **Full purge:** quit the app, then `rm -rf ~/.manbok`. Gone.

## License

[MIT](LICENSE) — do what you like; attribution appreciated.
