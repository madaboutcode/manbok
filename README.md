# upil-appa

Background microphone ring buffer for **macOS** (Apple Silicon). Keeps the last **10 minutes** of speech-grade audio in RAM and exports a WAV on demand — useful when another app’s recorder glitches or you want a safety copy of what you said.

**Default mode is opportunistic:** the daemon watches the system default mic and only captures while another app (Zoom, Voice Memos, Meet, etc.) is using it. When that session ends, capture stops, the ring is preserved, and a **5 second silence gap** is inserted so sessions are easy to separate in an editor.

## Requirements

- macOS 14+ (Apple Silicon)
- Xcode command-line tools / Swift 5.9+
- Microphone permission for the `upil-appa` binary (System Settings → Privacy & Security → Microphone)

## Install

Build a release binary and install into your user bin directory (idiomatic on macOS — no `sudo`):

```bash
git clone git@github.com:madaboutcode/upil-appa.git
cd upil-appa
make install
```

`make install` puts `upil-appa` in **`~/.local/bin`**. Add that to your shell `PATH` once:

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
| `upil-appa stop` | Stop daemon |
| `upil-appa status` | Phase + ring fill (`watching ring=1.2 MB (~6.0s)`) |
| `upil-appa dump` | Export ring to WAV (system temp dir) |
| `upil-appa dump --minutes 5` | Last N minutes only |

State: `~/.upil-appa/` (pid + Unix socket). Logs: Console.app → filter `subsystem:ai.upil.appa`.

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