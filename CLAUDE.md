# upil-appa

Background mic ring buffer for macOS: keeps the last 10 minutes of speech-grade PCM in RAM, exports WAV on demand.

## Commands (verified)

```bash
swift build
swift test
.build/debug/upil-appa start              # opportunistic (default): mic only when another app uses it
.build/debug/upil-appa start --always-on  # continuous capture (legacy)
.build/debug/upil-appa status    # stdout: watching | listening | stopped
.build/debug/upil-appa dump [--minutes N]   # stdout: absolute .wav path; opens Audacity
.build/debug/upil-appa stop
.build/debug/upil-appa --help
```

Mic permission: System Settings → Privacy & Security → Microphone (first capture).

## Jumpstart

**Updated:** 2026-06-03

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
| `tasks/` | Design, sprint bricks, progress | — |
| `spikes/` | Pre-implementation experiments (not shipped) | — |

### Directory Structure

```text
upil-appa/
├── Package.swift          # SPM: UpilAppaCore, UpilAppaPlatform, upil-appa
├── requirements.md        # Product spec
├── tasks/
│   ├── upil-appa.design.md   # Architecture (read before multi-file work)
│   ├── upil-appa.context.md  # Sprint verify commands
│   └── upil-appa.tasks.json  # Brick DAG
├── Sources/ …               # See module CLAUDE.md files
└── spikes/                  # Validation spikes only
```

Deep architecture: read `tasks/upil-appa.design.md` when touching layers, IPC, or capture.

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
swift test && swift build
# Manual: start → speak → dump → confirm WAV + Audacity; stop → status stopped
```

## Design & Documentation

- Before multi-component features, read `~/.agents/skills/software-design/SKILL.md` and follow its process.
- System design source of truth: `tasks/upil-appa.design.md` (promote to root `DESIGN.md` when stabilizing).
- Maintain CONTRACT blocks in source files when changing guarantees.
- When behavior changes, update `tasks/upil-appa.design.md` and relevant module `CLAUDE.md`.

## Testing

- Read `~/.agents/skills/writing-unit-tests/SKILL.md` before writing tests.
- Test contracts: GUARANTEES and FAILURE BEHAVIOR from CONTRACT blocks.
- Ring wrap test is slow (~7s) — do not delete without a faster equivalent.