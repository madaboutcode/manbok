# upil-appa

> *because Man-bok never misses a word*

Background microphone ring buffer for **macOS** (Apple Silicon). Keeps the last **10 minutes** of speech-grade audio in RAM and exports a WAV on demand — useful when another app's recorder glitches or you want a safety copy of what you said.

## Why *upil-appa*?

Named after [**Jung Man-bok**](https://en.wikipedia.org/wiki/Crash_Landing_on_You#People_in_the_North_Korean_Forces) (정만복), the wiretapper in [*Crash Landing on You*](https://en.wikipedia.org/wiki/Crash_Landing_on_You) — always listening, never missing a word. His son is **Jung U-pil** (우필); his wife calls him **"U-pil appa"** (우필 아빠), the usual Korean "[child's name] + appa" way of addressing a father. This project is that nickname as a Mac listener with an on-demand **`dump`**.

**Default mode is opportunistic:** the daemon watches the system default mic and only captures while another app (Zoom, Voice Memos, Meet, etc.) is using it. When that session ends, capture stops, the ring is preserved, and a **5 second silence gap** is inserted so sessions are easy to separate in an editor.

## Install

**Requirements:** macOS 14+, Apple Silicon, Xcode Command Line Tools (`xcode-select --install`).

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/madaboutcode/upil-appa/main/install.sh | bash
```

This clones, builds a release binary, installs it to `~/.local/bin`, and sets up a LaunchAgent so the daemon starts at login.

### From source

```bash
git clone https://github.com/madaboutcode/upil-appa.git
cd upil-appa
make install-launchagent    # build + install + LaunchAgent
```

Or just the binary (no login persistence):

```bash
make install                # release build → ~/.local/bin/upil-appa
```

Custom prefix: `make install PREFIX=/opt/homebrew`

### PATH

If `~/.local/bin` isn't in your PATH, add it once:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### Microphone permission

Approve the system prompt when it first appears, or grant access manually: System Settings → Privacy & Security → Microphone.

### Uninstall

```bash
# Remove LaunchAgent and binary
make uninstall-launchagent
make uninstall
```

Or manually:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.upil.appa.plist
rm -f ~/Library/LaunchAgents/com.upil.appa.plist ~/.local/bin/upil-appa
```

## User Guide

### Quick start

```bash
upil-appa status               # check daemon state
# Start recording in another app (Zoom, Voice Memos, etc.)
upil-appa status               # watching ring=0.3 MB (~9.2s)
upil-appa dump                 # export latest session → opens in Audacity
upil-appa stop                 # stop daemon
```

If you installed the LaunchAgent, the daemon is already running. Otherwise start it manually:

```bash
upil-appa start                # opportunistic daemon (background)
```

### Foreground mode

Run with a live terminal meter (useful for debugging — needs a second terminal for dump/stop):

```bash
upil-appa start --foreground
```

### Always-on mode

Capture continuously without waiting for another app to use the mic:

```bash
upil-appa start --always-on
```

### Sessions

The ring keeps a 5-second silence gap between recording sessions. Browse and export them:

```bash
upil-appa dump --list          # list sessions with relative timestamps
upil-appa dump                 # export newest session (default)
upil-appa dump last            # same as bare dump
upil-appa dump 1               # export by session id (oldest = 1)
upil-appa dump -1              # session before the newest
upil-appa dump -2              # two sessions back
upil-appa dump all             # full ring (session gaps omitted in export)
upil-appa dump --minutes 5     # last N minutes of ring
```

### CLI reference

| Command | Description |
|---------|-------------|
| `upil-appa start` | Opportunistic daemon (background) |
| `upil-appa start --foreground` | Same, with live terminal meter |
| `upil-appa start --always-on` | Continuous capture |
| `upil-appa authorize` | Request microphone access (run once from Terminal) |
| `upil-appa stop` | Stop daemon |
| `upil-appa status` | Phase + ring fill (`watching ring=1.2 MB (~6.0s)`) |
| `upil-appa dump` | Export newest session |
| `upil-appa dump all` | Export full ring |
| `upil-appa dump --list` | List sessions (5s gap markers; relative times) |
| `upil-appa dump 1` | Export session by id (oldest = 1) |
| `upil-appa dump last` | Same as bare `dump` |
| `upil-appa dump -1` | Session before the newest |
| `upil-appa dump --minutes 5` | Last N minutes of ring |
| `upil-appa sessions` | Alias for `dump --list` |

State: `~/.upil-appa/` (pid + Unix socket). Logs: Console.app → `subsystem:ai.upil.appa`; LaunchAgent also writes `/tmp/upil-appa.stderr.log`.

## How it works

```text
CLI (short-lived) ──IPC──► daemon (long-lived) ──► AVAudioEngine ──► byte ring (~19.2 MB)
                              └── dump ──► temp WAV ──► Audacity (optional)
```

- **Audio:** mono 16 kHz, 16-bit PCM (~32 KB/s); ring overwrites oldest data in place.
- **Opportunistic stop:** speech-quiet → brief release probe → stop when the default input is idle; ring not cleared.
- **Session marker:** 5 s of digital silence appended after each opportunistic session.

## Development

Clone and build:

```bash
git clone https://github.com/madaboutcode/upil-appa.git
cd upil-appa
make build                  # debug build
make test                   # run tests
make verify                 # test + build
make dev                    # build, restart, foreground meter
```

All make targets: `make help`

| Target | What it does |
|--------|-------------|
| `make build` | Debug build |
| `make release` | Release build |
| `make test` | `swift test` |
| `make verify` | test + build |
| `make install` | Release → `~/.local/bin` (restarts LaunchAgent if present) |
| `make install-launchagent` | Install + user LaunchAgent |
| `make uninstall-launchagent` | Remove LaunchAgent |
| `make uninstall` | Stop daemon, remove binary |
| `make authorize` | Request mic permission |
| `make dev` | Build, stop, start foreground |
| `make start` / `start-fg` / `start-always-on` | Run daemon (various modes) |
| `make stop` / `status` / `sessions` / `dump` | Daemon control |

Architecture: `tasks/upil-appa.design.md`, module `CLAUDE.md` files.

## License

Private repository — all rights reserved unless otherwise agreed by the owner.
