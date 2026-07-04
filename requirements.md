# manbok

> because Man-bok never misses a word

Named after **Jung Man-bok** (정만복), wiretapper in [*Crash Landing on You*](https://en.wikipedia.org/wiki/Crash_Landing_on_You). Son **Jung U-pil** (우필); wife calls him **“U-pil appa”** (우필 아빠). **manbok** = that nickname as a macOS ring-buffer listener.

A background audio ring buffer for macOS. Continuously captures microphone audio, keeps the last 10 minutes in memory, and lets you dump it to a WAV file on demand.

## Problem

Speech-to-text software sometimes glitches and doesn't record. You end up having to repeat yourself. This tool runs quietly in the background, always listening, so you never lose what you said.

## What It Does

- Continuously records mono microphone audio in the background
- Stores the last 10 minutes in RAM (ring buffer, no disk writes)
- Lets you recover audio on demand by dumping it to a WAV file
- Does not interfere with other applications using the microphone
- Very low resource usage — meant to run 24/7

## Commands

```
manbok start          # start background recording
manbok dump [minutes] # dump last N minutes to WAV (default: all)
manbok stop           # stop background recording
manbok status         # is appa listening?
```

## Technical Constraints

- **Platform:** macOS (Apple Silicon)
- **Language:** Swift (SPM)
- **Dependencies:** None — native macOS frameworks only (AVFoundation, CoreAudio)
- **Audio format:** 16 kHz, mono, 16-bit PCM (speech-to-text grade)
- **Memory usage:** ~19.2 MB for 10 minutes of audio
- **Disk writes:** None during continuous recording. WAV files written only on explicit dump.
- **Mic sharing:** Must coexist with other apps using the microphone simultaneously

## Output

A standard WAV file (RIFF format, uncompressed PCM) that can be opened in any audio editor (e.g., Oda City) for visual inspection, trimming, and onward use with speech-to-text tools.

## Out of Scope

- Waveform visualization in terminal
- Automatic silence detection / speech segmentation
- Interactive segment selection
- Menu bar GUI
- Any processing beyond raw capture and export
