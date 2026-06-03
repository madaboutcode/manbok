# upil-appa

> *because Man-bok never misses a word*

Background microphone ring buffer for **macOS** (Apple Silicon). Keeps the last **10 minutes** of speech-grade audio in RAM and exports a WAV on demand — useful when another app’s recorder glitches or you want a safety copy of what you said.

## Why *upil-appa*?

From [*Crash Landing on You*](https://en.wikipedia.org/wiki/Crash_Landing_on_You) (*사랑의 불시착*, 2019–2020).

**[Jung Man-bok](https://en.wikipedia.org/wiki/Crash_Landing_on_You#People_in_the_North_Korean_Forces)** (정만복, [Kim Young-min](https://en.wikipedia.org/wiki/Kim_Young-min_(actor))) is the North Korean **wiretapper** assigned to monitor Captain Ri Jeong-hyeok. Villagers nickname him ***gwittaegi*** (귀때기 — “The Rat”): despised, always listening, yet he catches what everyone else misses. Coerced into serving antagonist Cho Cheol-gang, haunted by his role in Ri Mu-hyeok’s death, he eventually sides with Jeong-hyeok and Yoon Se-ri. (Writers and fans often compare him to the listener in [*The Lives of Others*](https://en.wikipedia.org/wiki/The_Lives_of_Others).)

His family: wife **Hyun Myeong-sun** (현명선), son **[Jung U-pil](https://mydramalist.com/people/18931-oh-han-kyul)** (정우필 / 우필 — “Man Bok’s son” in the cast list). In Korean, Myeong-sun addresses her husband the way many wives do: **“U-pil appa”** (우필 아빠) — “U-pil’s dad” — not “Man-bok,” but the father role tied to their child.

**upil-appa** is that address turned into software: the household name for the guy who’s always on the wire, plus a **`dump`** when you need the recording.

| Piece | In the drama | In this repo |
|-------|----------------|--------------|
| **U-pil** (우필) | Man-bok’s son | — |
| **appa** (아빠) | What Myeong-sun calls her husband | Background listener |
| **upil-appa** | Jung Man-bok at home | CLI + daemon on your Mac |

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