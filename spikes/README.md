# upil-appa spikes

Lightweight validation before implementation. Run from this directory:

```bash
swift run ring-math-spike
swift run wav-spike          # writes spike-out.wav
swift run capture-spike 3    # needs mic permission
# IPC: server in one terminal, client in another
swift run ipc-spike server
swift run ipc-spike client
```

## Results (2026-06-03)

| Spike | Question | Result |
|-------|----------|--------|
| ring-math | 10 min buffer size | **PASS** — 19,200,000 bytes (19.2 MB decimal) |
| wav | RIFF PCM export | **PASS** — `file(1)` reports mono 16 kHz PCM |
| capture | 16 kHz mono from mic via AVAudioEngine | **PASS** — 48 kHz device → converter → ~16k samples/s, non-zero peaks |
| ipc | CLI ↔ daemon on Unix socket | **PASS** — request/response over `/tmp/upil-appa-spike.sock` |
| mic-share | Coexist with Zoom/Meet/etc. | **MANUAL** — see below |

### Manual: mic sharing

1. Start Zoom/Meet/FaceTime (or any app using the mic).
2. Run `swift run capture-spike 5` while speaking in that app.
3. **Pass** if both apps receive audio (capture spike shows peaks; other app still records).

If this fails, fallback options: investigate `AVAudioSession`-style aggregate routing on macOS, or document that simultaneous capture is best-effort.