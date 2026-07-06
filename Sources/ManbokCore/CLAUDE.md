# ManbokCore

Pure domain + application logic. **No AVFoundation, no FileManager paths in use cases** (ports only).

## Jumpstart

**Updated:** 2026-06-03

### What This Module Owns

Fixed-format PCM ring buffer, WAV header encoding, dump byte-range math, listener use cases, and IPC message types (bare-verb request parsing, NDJSON response serialization/parsing — no sockets here).

### Mental Model

```text
AudioCapturing (port) ──► SessionRegistry ──► ByteRingBuffer
                               ▲
ListenerService ───────────────┘ (legacy/debug)
       └── dump ──► WavPCMEncoder + DumpSink (port)
```

### Layout

| Folder | Files |
|--------|--------|
| `Domain/` | `AudioFormat`, `ByteRingBuffer`, `BufferPolicy`, `DumpRange`, `DumpSessionSelector`, `RingBufferSummary`, `SessionSummary` (+Display), `WaveformSampler`, `WavPCMEncoder`, `AppEvent` |
| `Audio/` | `AudioActivitySnapshot`, `SpeechActivityDetector` |
| `Ports/` | `AudioCapturing`, `DumpSink` |
| `Application/` | `SessionRegistry`, `ListenerService` |
| `Persistence/` | `CheckpointManifest` — Codable manifest for quit/launch state persistence |
| `IPC/` | `IPCCommand`, `IPCResponse` |

### Key Types

- `AudioFormat.capacityBytes` → 19_200_000 (10 min @ 16 kHz mono s16le)
- `ListenerError` — `.notListening`, `.emptyBuffer`, `.sessionNotFound(UInt64)`
- `ByteRingBuffer.slice(lastBytes:)` → 1–2 `Data` segments in time order
- `SessionRegistry` — one open session per bundle ID over a shared ring; stable monotonic `UInt64` ids; replaces `RecordingSession`
- `BufferPolicy.Preset` — ring size presets (`min5`...`min120`); `sessionsLost` computes resize impact before committing
- `WaveformSampler` — finalizes peak data for a closed session's waveform display
- `CheckpointManifest` — pure Codable schema for persisting ring + session state on quit; peaks are NOT stored (recomputed from PCM on restore)

### Tests

`Tests/ManbokCoreTests/` — ring, WAV, IPC parse, listener mocks.

```bash
swift test --filter ManbokCoreTests
```

## Constraints

- New I/O → new port in `Ports/`, implement in `ManbokPlatform`.
- `SessionRegistry` owns serialization of ring writes (queue).
- `ListenerService.dump` requires non-empty PCM in the ring (works after capture stops).
- No `print()` in Core — logging belongs at edges (`AppLog`).

## Testing

- Prefer testing `ByteRingBuffer`, `DumpRange`, `WavPCMEncoder` without mocks.
- `ListenerServiceTests` uses mock `AudioCapturing` + `DumpSink`.