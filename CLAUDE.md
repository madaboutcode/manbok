# manbok

Background mic ring buffer for macOS: keeps the last 10 minutes of speech-grade PCM in RAM, exports WAV on demand.

## Commands

Prefer **`make`** (see `Makefile` or `make help`). Builds `.build/debug/manbok` when needed.

```bash
make build              # swift build (debug)
make release            # swift build -c release → .build/release/manbok
make test               # swift test
make verify             # test + build
make install            # release → ~/.local/bin/manbok (restarts LaunchAgent if present)
make install-launchagent # install + user LaunchAgent (Aqua session; login persistence)
make authorize          # mic permission for this binary (Terminal)

make start              # opportunistic daemon (background)
make start-fg           # foreground + live meter — run dump/stop in **another terminal**
make start-always-on    # continuous capture (background)
make stop
make status             # stdout: phase + ring size (e.g. watching ring=empty)
make dump               # export newest session (default)
make dump TARGET=all    # full ring
make dump TARGET=-1     # prior session
make dump MINUTES=5     # last N minutes of ring

make app                # build + assemble Manbok.app (.build/Manbok.app)
make install-app        # app → ~/Applications/Manbok.app
make run-app             # build + open Manbok.app (foreground GUI, no daemon)
```

Mic permission: System Settings → Privacy & Security → Microphone (first capture).

Foreground meter: TTY UI on stdout; daemon diagnostics → Console (`subsystem:ai.manbok.app`). CLI subcommands still mirror hints to stderr.

## Jumpstart

**Updated:** 2026-06-04

### What This Project Does

Native macOS menu bar app (SwiftUI) that always-on-records mono 16 kHz PCM per foreground app into a shared byte ring (5–120 min, configurable). No disk until export. A CLI still exists for scripting/debugging and talks to the running app over a Unix socket.

### System Mental Model

```text
CLI (short-lived) ──IPC──► App (long-lived) ──► CaptureOrchestrator ──► AVAudioEngine ──► ring buffer
                              ├── PopoverViewModel ──► SwiftUI views
                              └── dump ──► temp WAV ──► Finder reveal / clipboard
```

State lives in `~/.manbok/` (pid + socket). Dump files go to the system temp directory.

### Module Map

| Path | Owns | CLAUDE.md |
|------|------|-----------|
| `Sources/ManbokCore/` | Domain, ports, application use cases, IPC types | Yes |
| `Sources/ManbokPlatform/` | AVFoundation capture, sockets, files, logging, daemon spawn | Yes |
| `Sources/ManbokApp/` | SwiftUI app: entry point, views, view model | Yes |
| `Sources/manbok/` | CLI + daemon entry (`Main`, `DaemonMain`) | Yes |
| `Tests/` | XCTest for Core + Platform | — |
| `tasks/` | Internal planning files (not tracked) | — |
| `spikes/` | Pre-implementation experiments (not shipped) | — |

### Directory Structure

```text
manbok/
├── Package.swift          # SPM: ManbokCore, ManbokPlatform, manbok
├── requirements.md        # Product spec
├── ARCHITECTURE.md        # System design (read before multi-file work)
├── tasks/                 # Internal planning files (not tracked in git)
├── Sources/ …               # See module CLAUDE.md files
└── spikes/                  # Validation spikes only
```

Deep architecture: read `ARCHITECTURE.md` when touching layers, IPC, or capture.

Daemon/IPC issues: read `docs/claude-references/runtime.md`.

## Conventions

- **Layers:** Core has no AVFoundation; Platform implements Core ports; executable only routes CLI/daemon.
- **Contracts:** `// MARK: - CONTRACT` blocks at top of component files — keep aligned with design.
- **Logging:** `AppLog` + `os.Logger` subsystem `ai.manbok.app`; diagnostics on **stderr**, primary output on **stdout**.
- **IPC:** Bare-verb requests (`PING`, `STATUS`, `STOP`, `DUMP [minutes]`); NDJSON responses (one JSON object per line, `v:1` + `type` discriminator) → see `Sources/ManbokCore/IPC/`.
- **Dependencies:** Native macOS only in libraries; **ArgumentParser** only on the `manbok` executable.

## Constraints

| Rule | Why |
|------|-----|
| No AVFoundation in `ManbokCore` | Keeps domain unit-testable without mic/hardware |
| Do not stream audio over the Unix socket | Dump writes a file; CLI prints path |
| Do not add third-party deps without discussion | Spec mandates native frameworks |

## Verification

```bash
make verify
# Manual: make start-fg (tab 1) → REC on meter → make dump (tab 2) → WAV; make stop (tab 2)
```

## Design & Documentation

- Before multi-component features, read `~/.agents/skills/software-design/SKILL.md` and follow its process.
- System design source of truth: `ARCHITECTURE.md`.
- Maintain CONTRACT blocks in source files when changing guarantees.
- When behavior changes, update `ARCHITECTURE.md` and relevant module `CLAUDE.md`.

## Testing

- Read `~/.agents/skills/writing-unit-tests/SKILL.md` before writing tests.
- Test contracts: GUARANTEES and FAILURE BEHAVIOR from CONTRACT blocks.
- Ring wrap test is slow (~7s) — do not delete without a faster equivalent.