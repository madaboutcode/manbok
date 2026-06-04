# upil-appa

Background mic ring buffer for macOS: keeps the last 10 minutes of speech-grade PCM in RAM, exports WAV on demand.

## Commands

Prefer **`make`** (see `Makefile` or `make help`). Builds `.build/debug/upil-appa` when needed.

```bash
make build              # swift build (debug)
make release            # swift build -c release → .build/release/upil-appa
make test               # swift test
make verify             # test + build
make install            # release → ~/.local/bin/upil-appa (restarts LaunchAgent if present)
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
```

Mic permission: System Settings → Privacy & Security → Microphone (first capture).

Foreground meter: TTY UI on stdout; daemon diagnostics → Console (`subsystem:ai.upil.appa`). CLI subcommands still mirror hints to stderr.

## Jumpstart

**Updated:** 2026-06-04

### What This Project Does

Always-on listener daemon records mono 16 kHz PCM into a fixed-size byte ring (~19.2 MB). No disk until `dump`. CLI controls the daemon over a Unix socket and opens the WAV in Audacity for trimming.

### System Mental Model

```text
CLI (short-lived) ──IPC──► daemon (long-lived) ──► AVAudioEngine ──► ring buffer
                              └── dump ──► temp WAV ──► CLI opens Audacity
```

State lives in `~/.upil-appa/` (pid + socket). Dump files go to the system temp directory.

### Module Map

| Path | Owns | CLAUDE.md |
|------|------|-----------|
| `Sources/UpilAppaCore/` | Domain, ports, application use cases, IPC types | Yes |
| `Sources/UpilAppaPlatform/` | AVFoundation capture, sockets, files, logging, daemon spawn | Yes |
| `Sources/upil-appa/` | CLI + daemon entry (`Main`, `DaemonMain`) | Yes |
| `Tests/` | XCTest for Core + Platform | — |
| `tasks/` | Internal planning files (not tracked) | — |
| `spikes/` | Pre-implementation experiments (not shipped) | — |

### Directory Structure

```text
upil-appa/
├── Package.swift          # SPM: UpilAppaCore, UpilAppaPlatform, upil-appa
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
- **Logging:** `AppLog` + `os.Logger` subsystem `ai.upil.appa`; diagnostics on **stderr**, primary output on **stdout**.
- **IPC:** Line protocol — `PING`, `STATUS`, `STOP`, `DUMP [minutes]` → see `Sources/UpilAppaCore/IPC/`.
- **Dependencies:** Native macOS only in libraries; **ArgumentParser** only on the `upil-appa` executable.

## Constraints

| Rule | Why |
|------|-----|
| No AVFoundation in `UpilAppaCore` | Keeps domain unit-testable without mic/hardware |
| No `print()` in Core | Logging belongs at edges (`AppLog`) |
| Do not stream audio over the Unix socket | Dump writes a file; CLI prints path |
| `stop` must exit the daemon | Orphan pid breaks `status`/`dump` |
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