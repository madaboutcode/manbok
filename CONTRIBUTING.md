# Contributing to manbok

Thanks for looking under the hood. The short version: build with `make`, keep the
layers clean, and prove your change works.

## Build and test

```bash
make build      # debug build
make test       # swift test
make verify     # test + build (run this before opening a PR)
make run-app    # build + open Manbok.app
```

Requirements: macOS 14+, Apple Silicon, Xcode Command Line Tools.

## Ground rules

- **Layers:** `ManbokCore` has no AVFoundation (keeps the domain testable without
  hardware). `ManbokPlatform` implements Core's ports. The `manbok` executable only
  routes CLI/daemon. Don't cross these.
- **No third-party dependencies** in the libraries. ArgumentParser is allowed on the
  CLI executable only. This is a deliberate constraint, not an oversight.
- **CONTRACT blocks:** component files carry a `// MARK: - CONTRACT` comment stating
  guarantees and failure behavior. If your change alters a guarantee, update the
  contract, and check whether `ARCHITECTURE.md` or `docs/specs/` need the same change.
- **Specs:** user-observable behavior is specified in `docs/specs/`. A failing
  spec-enforcement test is a bug report against the code, not the test.

## Pull requests

- Run `make verify` locally; CI runs the same on your PR.
- Keep PRs focused. If you found a second problem on the way, open an issue.
- Behavior change? Say what changed and how you verified it (a WAV dumped, a log
  line, a screenshot) — not just "tests pass."

## Docs worth reading first

- `ARCHITECTURE.md` — system design (read before multi-file changes)
- `docs/specs/` — what the app promises users
- `docs/claude-references/runtime.md` — daemon/IPC debugging
