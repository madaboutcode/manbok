# upil-appa

> *because Man-bok never misses a word*

Background microphone ring buffer for **macOS** (Apple Silicon). Keeps the last **10 minutes** of speech-grade audio in RAM and exports a WAV on demand — useful when another app’s recorder glitches or you want a safety copy of what you said.

## Why *upil-appa*?

Named after [**Jung Man-bok**](https://en.wikipedia.org/wiki/Crash_Landing_on_You#People_in_the_North_Korean_Forces) (정만복), the wiretapper in [*Crash Landing on You*](https://en.wikipedia.org/wiki/Crash_Landing_on_You) — always listening, never missing a word. His son is **Jung U-pil** (우필); his wife calls him **“U-pil appa”** (우필 아빠), the usual Korean “[child’s name] + appa” way of addressing a father. This project is that nickname as a Mac listener with an on-demand **`dump`**.

**Default mode is opportunistic:** the daemon watches the system default mic and only captures while another app (Zoom, Voice Memos, Meet, etc.) is using it. When that session ends, capture stops, the ring is preserved, and a **5 second silence gap** is inserted so sessions are easy to separate in an editor.

## Requirements

- macOS 14+ (Apple Silicon)
- Xcode command-line tools / Swift 5.9+
- Microphone permission for the `upil-appa` binary: `upil-appa authorize` or `make authorize` from Terminal (or System Settings → Privacy & Security → Microphone)

## Install

Build a release binary, install into your user bin directory, and start the background daemon (restarts it if already running):

```bash
git clone git@github.com:madaboutcode/upil-appa.git
cd upil-appa
make install
```

`make install` puts `upil-appa` in **`~/.local/bin`** and runs **`upil-appa start`** (opportunistic, detached). Add that directory to your shell `PATH` once:

```bash
# ~/.zshrc or ~/.bashrc
export PATH="$HOME/.local/bin:$PATH"
```

Custom prefix:

```bash
make install PREFIX=/opt/homebrew
```

Uninstall:

```bash
make uninstall
```

**Login persistence (recommended for background use):** user LaunchAgent in your GUI session (better mic routing than a bare detached daemon):

```bash
make install-launchagent   # installs binary, authorize, loads ~/Library/LaunchAgents/com.upil.appa.plist
```

Approve the microphone prompt when it appears. Logs: `/tmp/upil-appa.stderr.log`. Remove with `make uninstall-launchagent`.

Use **`make install`** for a one-shot detached daemon (no launchd). Do not run both at once.

Other install options people use: [Homebrew](https://brew.sh) formula (best for wide distribution), or `swift build -c release` and copy the binary from `.build/release/` yourself.

## Quick start

```bash
make dev          # build, stop stale daemon, foreground meter
# In another terminal, after you record elsewhere:
make status       # e.g. watching ring=0.3 MB (~9.2s)
make dump         # WAV path on stdout; opens in Audacity if installed
make stop
```

Background daemon:

```bash
make start        # opportunistic, detached
make status
upil-appa dump --list
upil-appa dump          # newest session (default)
upil-appa dump -1       # session before that
upil-appa dump all      # full ring (session gaps omitted in export)
make dump MINUTES=5
make stop
```

Always-on (continuous capture, no external app required):

```bash
make start-always-on
```

## CLI

| Command | Description |
|---------|-------------|
| `upil-appa start` | Opportunistic daemon (background) |
| `upil-appa start --foreground` | Same, with live terminal meter on stdout |
| `upil-appa start --always-on` | Continuous capture |
| `upil-appa authorize` | Request microphone access (run once from Terminal) |
| `upil-appa stop` | Stop daemon |
| `upil-appa status` | Phase + ring fill (`watching ring=1.2 MB (~6.0s)`) |
| `upil-appa dump` | Export **newest** session (default) |
| `upil-appa dump all` | Export full ring to WAV |
| `upil-appa dump --list` | List sessions (5s gap markers; relative times) |
| `upil-appa dump 1` | Export session by id (oldest = 1) |
| `upil-appa dump last` | Same as bare `dump` (newest) |
| `upil-appa dump -1` | Session **before** the newest |
| `upil-appa dump -2` | Two before the newest |
| `upil-appa dump --minutes 5` | Last N minutes of ring (not a session id) |
| `upil-appa sessions` | Same as `upil-appa dump --list` |

State: `~/.upil-appa/` (pid + Unix socket). Logs: Console.app → `subsystem:ai.upil.appa`; LaunchAgent also writes `/tmp/upil-appa.stderr.log`.

Exported session WAVs omit the 5s ring markers (gaps stay in the ring for `dump --list` only).

## How it works

```text
CLI (short-lived) ──IPC──► daemon (long-lived) ──► AVAudioEngine ──► byte ring (~19.2 MB)
                              └── dump ──► temp WAV ──► Audacity (optional)
```

- **Audio:** mono 16 kHz, 16-bit PCM (~32 KB/s); ring overwrites oldest data in place.
- **Opportunistic stop:** speech-quiet → brief release probe → stop when the default input is idle; ring not cleared.
- **Session marker:** 5 s of digital silence appended after each opportunistic session.

## Development

```bash
make verify       # swift test + debug build
make help
```

Architecture and agent notes: `tasks/upil-appa.design.md`, `CLAUDE.md`.

Pre-ship spikes live under `spikes/` (not part of the main product target).

## License

Private repository — all rights reserved unless otherwise agreed by the owner.