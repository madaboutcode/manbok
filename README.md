# manbok

> *because Man-bok never misses a word*

Background microphone ring buffer for **macOS** (Apple Silicon). Keeps the last **10 minutes** of speech-grade audio in RAM and exports a WAV on demand — useful when another app's recorder glitches or you want a safety copy of what you said.

## Why *manbok*?

Named after [**Jung Man-bok**](https://en.wikipedia.org/wiki/Crash_Landing_on_You#People_in_the_North_Korean_Forces) (정만복), the wiretapper in [*Crash Landing on You*](https://en.wikipedia.org/wiki/Crash_Landing_on_You) — always listening, never missing a word. His son is **Jung U-pil** (우필); his wife calls him **"U-pil appa"** (우필 아빠), the usual Korean "[child's name] + appa" way of addressing a father. This project is that nickname as a Mac listener with an on-demand **`dump`**.

**Default mode is opportunistic:** the daemon watches the system default mic and only captures while another app (Zoom, Voice Memos, Meet, etc.) is using it. When that session ends, capture stops, the ring is preserved, and a **5 second silence gap** is inserted so sessions are easy to separate in an editor.

## Install

**Requirements:** macOS 14+, Apple Silicon, Xcode Command Line Tools (`xcode-select --install`).

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/madaboutcode/manbok/main/install.sh | bash
```

This clones, builds a release binary, installs it to `~/.local/bin`, and sets up a LaunchAgent so the daemon starts at login.

### From source

```bash
git clone https://github.com/madaboutcode/manbok.git
cd manbok
make install-launchagent    # build + install + LaunchAgent
```

Or just the binary (no login persistence):

```bash
make install                # release build → ~/.local/bin/manbok
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
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.manbok.app.plist
rm -f ~/Library/LaunchAgents/com.manbok.app.plist ~/.local/bin/manbok
```

## User Guide

### Quick start

```bash
manbok status               # check daemon state
# Start recording in another app (Zoom, Voice Memos, etc.)
manbok status               # watching ring=0.3 MB (~9.2s)
manbok dump                 # export latest session → opens in Audacity
manbok stop                 # stop daemon
```

If you installed the LaunchAgent, the daemon is already running. Otherwise start it manually:

```bash
manbok start                # opportunistic daemon (background)
```

### Foreground mode

Run with a live terminal meter (useful for debugging — needs a second terminal for dump/stop):

```bash
manbok start --foreground
```

### Always-on mode

Capture continuously without waiting for another app to use the mic:

```bash
manbok start --always-on
```

### Sessions

The ring keeps a 5-second silence gap between recording sessions. Browse and export them:

```bash
manbok dump --list          # list sessions with relative timestamps
manbok dump                 # export newest session (default)
manbok dump last            # same as bare dump
manbok dump 1               # export by session id (oldest = 1)
manbok dump -1              # session before the newest
manbok dump -2              # two sessions back
manbok dump all             # full ring (session gaps omitted in export)
manbok dump --minutes 5     # last N minutes of ring
```

### CLI reference

| Command | Description |
|---------|-------------|
| `manbok start` | Opportunistic daemon (background) |
| `manbok start --foreground` | Same, with live terminal meter |
| `manbok start --always-on` | Continuous capture |
| `manbok authorize` | Request microphone access (run once from Terminal) |
| `manbok stop` | Stop daemon |
| `manbok status` | Phase + ring fill (`watching ring=1.2 MB (~6.0s)`) |
| `manbok dump` | Export newest session |
| `manbok dump all` | Export full ring |
| `manbok dump --list` | List sessions (5s gap markers; relative times) |
| `manbok dump 1` | Export session by id (oldest = 1) |
| `manbok dump last` | Same as bare `dump` |
| `manbok dump -1` | Session before the newest |
| `manbok dump --minutes 5` | Last N minutes of ring |
| `manbok sessions` | Alias for `dump --list` |

State: `~/.manbok/` (pid + Unix socket). Logs: Console.app → `subsystem:ai.manbok.app`; LaunchAgent also writes `/tmp/manbok.stderr.log`.

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
git clone https://github.com/madaboutcode/manbok.git
cd manbok
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

Architecture: `tasks/manbok.design.md`, module `CLAUDE.md` files.

## License

Private repository — all rights reserved unless otherwise agreed by the owner.
