// Spike: measure how fast kAudioDevicePropertyDeviceIsRunningSomewhere settles after engine stop.
//
// Question: can we reduce the 0.5s settle wait (in InputDeviceObserver / "mic busy" check)
// to 50–100ms and avoid unnecessary audio loss?
//
// Build:
//   swiftc main.swift -framework CoreAudio -framework AVFoundation -o settle-timing
// Run:
//   ./settle-timing
//
// IMPORTANT: close any other app that uses the mic before running, otherwise the property
// will stay true (another client still holds IO) and the spike will warn you.

import AVFoundation
import CoreAudio
import Foundation

// ---------------------------------------------------------------------------
// mach_absolute_time helpers — sub-millisecond resolution
// ---------------------------------------------------------------------------

private var timebaseInfo: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

/// Elapsed nanoseconds since an arbitrary origin — monotonic, sub-µs resolution.
private func machNow() -> UInt64 {
    mach_absolute_time()
}

/// Convert a mach_absolute_time delta to milliseconds (Double).
private func machToMs(_ delta: UInt64) -> Double {
    let nanos = Double(delta) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
    return nanos / 1_000_000.0
}

// ---------------------------------------------------------------------------
// CoreAudio helpers (mirrors InputDeviceObserver patterns)
// ---------------------------------------------------------------------------

private func defaultInputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    ) == noErr, deviceID != kAudioObjectUnknown else {
        return nil
    }
    return deviceID
}

private func deviceName(_ deviceID: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &unmanaged) == noErr,
          let cf = unmanaged?.takeRetainedValue() else {
        return "device \(deviceID)"
    }
    return cf as String
}

/// Returns true when some client has active IO on this device.
private func isRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
        return false
    }
    return value != 0
}

// ---------------------------------------------------------------------------
// Engine start/stop + settle timing
// ---------------------------------------------------------------------------

/// Install a minimal tap, start the engine, confirm property is true.
/// Returns the engine on success.
private func startEngine() throws -> AVAudioEngine {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let fmt = input.outputFormat(forBus: 0)
    // Minimal tap — install and discard all audio data immediately.
    input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { _, _ in }
    try engine.start()
    return engine
}

/// Stop the engine and return the mach timestamp immediately after stop() returns.
private func stopEngine(_ engine: AVAudioEngine) -> UInt64 {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    return machNow()
}

/// Poll `kAudioDevicePropertyDeviceIsRunningSomewhere` at ~5ms intervals until
/// it transitions to false, or until `timeoutMs` elapses.
/// Returns settle time in ms, or nil if timed out.
private func pollUntilFalse(
    deviceID: AudioDeviceID,
    stopTimestamp: UInt64,
    timeoutMs: Double = 2000.0,
    pollIntervalNs: UInt32 = 5_000_000   // 5ms
) -> Double? {
    let deadlineMs = timeoutMs
    while true {
        let now = machNow()
        let elapsedMs = machToMs(now &- stopTimestamp)

        if !isRunningSomewhere(deviceID) {
            return elapsedMs
        }

        if elapsedMs >= deadlineMs {
            return nil
        }

        // Sleep ~5ms between polls; nanosleep is more precise than usleep.
        var ts = timespec(tv_sec: 0, tv_nsec: Int(pollIntervalNs))
        nanosleep(&ts, nil)
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

guard let deviceID = defaultInputDeviceID() else {
    fputs("ERROR: no default input device found\n", stderr)
    exit(1)
}
print("Default input device: \(deviceName(deviceID)) [id=\(deviceID)]")

// Check mic permission.
let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
if authStatus == .denied || authStatus == .restricted {
    fputs(
        "ERROR: microphone access denied — grant in System Settings → Privacy → Microphone\n",
        stderr
    )
    exit(1)
}
if authStatus == .notDetermined {
    print("Requesting microphone permission...")
    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { _ in sem.signal() }
    sem.wait()
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        fputs("ERROR: microphone permission denied\n", stderr)
        exit(1)
    }
}

// Pre-run check: if something else already holds the mic, property may never go false.
if isRunningSomewhere(deviceID) {
    // We haven't started our engine yet, so another app must own the mic.
    fputs(
        """
        WARNING: kAudioDevicePropertyDeviceIsRunningSomewhere is already TRUE before we start.
        Another application is currently using the microphone. The property may never
        transition to false during this run, making results unreliable.
        Close the other app and re-run for clean measurements.

        """,
        stderr
    )
}

let runs = 10
let gapSeconds: TimeInterval = 2.0
var settleTimesMs: [Double] = []

print("\nRunning \(runs) iterations with \(Int(gapSeconds))s gap between each...")
print(String(repeating: "-", count: 60))

for run in 1...runs {
    // Start engine — allow time for HAL to register IO before we measure stop.
    let engine: AVAudioEngine
    do {
        engine = try startEngine()
    } catch {
        fputs("Run \(run): failed to start engine — \(error)\n", stderr)
        continue
    }

    // Short settle after start so HAL fully registers our IO before we stop.
    // This is NOT what we're measuring — it just ensures the property is reliably true.
    Thread.sleep(forTimeInterval: 0.3)

    // Confirm property is true before stopping.
    guard isRunningSomewhere(deviceID) else {
        print("Run \(run): WARNING — property was false before stop (another app may have stolen IO). Skipping.")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        Thread.sleep(forTimeInterval: gapSeconds)
        continue
    }

    // Stop and immediately begin timing.
    let t0 = stopEngine(engine)

    if let settleMs = pollUntilFalse(deviceID: deviceID, stopTimestamp: t0) {
        settleTimesMs.append(settleMs)
        print(String(format: "Run %2d: Engine stopped at T+0.000ms, property settled to false at T+%7.3fms", run, settleMs))
    } else {
        print(String(format: "Run %2d: TIMEOUT — property did not go false within 2000ms (another app using mic?)", run))
    }

    if run < runs {
        Thread.sleep(forTimeInterval: gapSeconds)
    }
}

print(String(repeating: "-", count: 60))

guard !settleTimesMs.isEmpty else {
    print("No valid measurements collected.")
    exit(1)
}

let sorted = settleTimesMs.sorted()
let minMs  = sorted.first!
let maxMs  = sorted.last!
let meanMs = settleTimesMs.reduce(0, +) / Double(settleTimesMs.count)

let medianMs: Double
let n = sorted.count
if n % 2 == 0 {
    medianMs = (sorted[n/2 - 1] + sorted[n/2]) / 2.0
} else {
    medianMs = sorted[n/2]
}

print(String(format: "\nSummary over %d valid run(s):", settleTimesMs.count))
print(String(format: "  min:    %7.3f ms", minMs))
print(String(format: "  max:    %7.3f ms", maxMs))
print(String(format: "  median: %7.3f ms", medianMs))
print(String(format: "  mean:   %7.3f ms", meanMs))
print("")
print("Interpretation:")
if maxMs < 50 {
    print("  Max < 50ms — safe to reduce settle wait to 50ms.")
} else if maxMs < 100 {
    print("  Max < 100ms — safe to reduce settle wait to 100ms.")
} else if maxMs < 250 {
    print("  Max < 250ms — consider 250ms settle wait.")
} else {
    print(String(format: "  Max %.0fms — current 500ms wait may be warranted; inspect outliers.", maxMs))
}
print("")
print("Note: these timings include polling granularity (~5ms). True settle may be slightly faster.")
