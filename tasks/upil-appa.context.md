# upil-appa sprint context

## Design
- `tasks/upil-appa.design.md`

## Verify
```bash
swift build
swift test
```

## Do NOT modify (orchestrator-owned)
- `Package.swift` unless adding a dependency — ask orchestrator

## Conventions
- Subsystem: `ai.upil.appa`
- stdout = primary output (one line); stderr = diagnostics via `AppLog`
- Dump path: `FileManager.default.temporaryDirectory` + `upil-appa-<timestamp>.wav`
- No third-party deps; ArgumentParser is OK as SPM dependency for CLI only

## Anti-patterns
- `print()` in UpilAppaCore
- AVFoundation import in UpilAppaCore
- stdout for log messages