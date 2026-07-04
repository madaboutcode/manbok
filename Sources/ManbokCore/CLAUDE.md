# ManbokCore

Pure domain + application logic. **No AVFoundation, no FileManager paths in use cases** (ports only).

## Jumpstart

**Updated:** 2026-06-03

### What This Module Owns

Fixed-format PCM ring buffer, WAV header encoding, dump byte-range math, listener use cases, and IPC message types (parse/serialize only — no sockets here).

### Mental Model

```text
AudioCapturing (port) ──► RecordingSession ──► ByteRingBuffer
                                ▲
ListenerService ────────────────┘
       └── dump ──► WavPCMEncoder + DumpSink (port)
```

### Layout

| Folder | Files |
|--------|--------|
| `Domain/` | `AudioFormat`, `ByteRingBuffer`, `DumpRange`, `WavPCMEncoder` |
| `Ports/` | `AudioCapturing`, `DumpSink` |
| `Application/` | `RecordingSession`, `ListenerService` |
| `IPC/` | `IPCCommand`, `IPCResponse` |

### Key Types

- `AudioFormat.capacityBytes` → 19_200_000 (10 min @ 16 kHz mono s16le)
- `ListenerError` — `.notListening`, `.emptyBuffer`
- `ByteRingBuffer.slice(lastBytes:)` → 1–2 `Data` segments in time order

### Tests

`Tests/ManbokCoreTests/` — ring, WAV, IPC parse, listener mocks.

```bash
swift test --filter ManbokCoreTests
```

## Constraints

- New I/O → new port in `Ports/`, implement in `ManbokPlatform`.
- `RecordingSession` owns serialization of ring writes (queue).
- `ListenerService.dump` requires non-empty PCM in the ring (works after capture stops).
- No `print()` in Core — logging belongs at edges (`AppLog`).

## Testing

- Prefer testing `ByteRingBuffer`, `DumpRange`, `WavPCMEncoder` without mocks.
- `ListenerServiceTests` uses mock `AudioCapturing` + `DumpSink`.