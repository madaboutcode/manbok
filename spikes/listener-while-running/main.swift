// Spike: Does kAudioDevicePropertyDeviceIsRunningSomewhere listener fire when another app
// releases the mic while OUR AVAudioEngine is still running?
//
// Build:
//   swiftc main.swift -framework CoreAudio -framework AVFoundation -o listener-test
// Run:
//   ./listener-test
//
// The key question: even when the property VALUE stays `true` (because we're still running),
// does the listener FIRE on another app's exit? If yes — the notification is itself the signal.
// If no — this path is dead for detecting external-app exit pre-Sonoma.

import AVFoundation
import CoreAudio
import Foundation

// MARK: - Timestamp

private func ts() -> String {
    let now = Date()
    let cal = Calendar(identifier: .gregorian)
    let comps = cal.dateComponents([.hour, .minute, .second], from: now)
    let ms = Int(now.timeIntervalSince1970 * 1000) % 1000
    return String(format: "%02d:%02d:%02d.%03d",
                  comps.hour ?? 0,
                  comps.minute ?? 0,
                  comps.second ?? 0,
                  ms)
}

// MARK: - CoreAudio helpers

private func defaultInputID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address, 0, nil, &size, &id
    ) == noErr, id != kAudioObjectUnknown else { return nil }
    return id
}

private func deviceName(_ id: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &unmanaged) == noErr,
          let cf = unmanaged?.takeRetainedValue() else { return "device \(id)" }
    return cf as String
}

/// Reads kAudioDevicePropertyDeviceIsRunningSomewhere — true when ANY client has active IO.
private func readIsRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
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

/// Reads kAudioDevicePropertyDeviceIsRunning — true when THIS PROCESS has active IO.
private func readIsRunning(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunning,
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

// MARK: - Engine

private func startEngine() throws -> AVAudioEngine {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    // Install a no-op tap — just enough to keep the engine doing real IO.
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }
    try engine.start()
    return engine
}

// MARK: - Listener registration

/// Returns a cleanup closure. Fires `handler` on the given queue whenever the property changes.
private func addPropertyListener(
    deviceID: AudioDeviceID,
    selector: AudioObjectPropertySelector,
    label: String,
    queue: DispatchQueue,
    handler: @escaping (String, Bool) -> Void
) -> () -> Void {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // We capture address by value inside the block for the re-read.
    let block: AudioObjectPropertyListenerBlock = { _, _ in
        // Re-read the current value from within the block (same selector).
        var innerAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(deviceID, &innerAddress, 0, nil, &size, &value)
        let boolValue = (err == noErr) ? (value != 0) : false
        handler(label, boolValue)
    }

    // AudioObjectAddPropertyListenerBlock retains the block — we keep a copy for removal.
    let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block)
    if status != noErr {
        print("[\(ts())] WARNING: AudioObjectAddPropertyListenerBlock failed for \(label) (err=\(status))")
    }

    return {
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
    }
}

// MARK: - Mic permission

private func ensureMic() throws {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return
    case .notDetermined:
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            granted = ok
            sem.signal()
        }
        sem.wait()
        guard granted else { throw NSError(domain: "spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone access denied"]) }
    default:
        throw NSError(domain: "spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone access denied"])
    }
}

// MARK: - Main

do {
    try ensureMic()

    guard let deviceID = defaultInputID() else {
        print("ERROR: no default input device found")
        exit(1)
    }

    let name = deviceName(deviceID)
    print("=======================================================")
    print("  listener-while-running spike")
    print("  Device: \(name) [id=\(deviceID)]")
    print("=======================================================")
    print("")
    print("INSTRUCTIONS:")
    print("  1. This spike will start its own AVAudioEngine tap immediately.")
    print("  2. AFTER you see 'Engine running', start ANOTHER app that uses the mic")
    print("     (e.g. QuickTime → New Audio Recording, or Voice Memos, or FaceTime).")
    print("  3. Let it run for a few seconds, then STOP that app's recording/call.")
    print("  4. Watch for listener callbacks and poll output below.")
    print("  5. The spike exits after 120 seconds.")
    print("")

    // Start engine first — this is the key condition we're testing under.
    let engine = try startEngine()
    print("[\(ts())] Engine running — our AVAudioEngine is now holding the mic.")
    print("")

    // Initial property reads.
    let initialRunningSomewhere = readIsRunningSomewhere(deviceID)
    let initialIsRunning = readIsRunning(deviceID)
    print("[\(ts())] Initial state:")
    print("  IsRunningSomewhere = \(initialRunningSomewhere) (expected: true — we are running)")
    print("  IsRunning          = \(initialIsRunning) (expected: true — our process has IO)")
    print("")
    print("  ↳ Now START another app that uses the mic...")
    print("")

    // Listener queue — use a dedicated serial queue so callbacks serialize cleanly.
    let listenerQ = DispatchQueue(label: "spike.listener", qos: .userInteractive)

    var listenerFireCount = [String: Int]()
    let countLock = NSLock()

    func onFire(_ label: String, _ value: Bool) {
        let stamp = ts()
        countLock.lock()
        listenerFireCount[label, default: 0] += 1
        let count = listenerFireCount[label]!
        countLock.unlock()
        print("[\(stamp)] LISTENER FIRED: \(label) → value=\(value)  (fire #\(count))")
    }

    // Register both listeners.
    let removeRunningSomewhere = addPropertyListener(
        deviceID: deviceID,
        selector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        label: "IsRunningSomewhere",
        queue: listenerQ,
        handler: onFire
    )

    let removeIsRunning = addPropertyListener(
        deviceID: deviceID,
        selector: kAudioDevicePropertyDeviceIsRunning,
        label: "IsRunning",
        queue: listenerQ,
        handler: onFire
    )

    print("[\(ts())] Listeners registered. Polling every 1s for 120s...")
    print("")

    // Poll loop — 120 iterations, 1s apart.
    for i in 1...120 {
        Thread.sleep(forTimeInterval: 1.0)
        let rsw = readIsRunningSomewhere(deviceID)
        let ir = readIsRunning(deviceID)
        print("[\(ts())] poll #\(String(format: "%03d", i))  IsRunningSomewhere=\(rsw ? 1 : 0)  IsRunning=\(ir ? 1 : 0)")
    }

    print("")
    print("=======================================================")
    print("  SUMMARY after 120s")
    print("=======================================================")
    countLock.lock()
    let rswFires = listenerFireCount["IsRunningSomewhere"] ?? 0
    let irFires  = listenerFireCount["IsRunning"] ?? 0
    countLock.unlock()

    print("  IsRunningSomewhere listener fired: \(rswFires) time(s)")
    print("  IsRunning listener fired:          \(irFires) time(s)")
    print("")

    if rswFires > 0 {
        print("  FINDING: IsRunningSomewhere DID fire while our engine was running.")
        print("  Even if the value stayed `true`, the notification itself is a detectable signal.")
        print("  → This path MAY be viable for detecting external-app exit.")
    } else {
        print("  FINDING: IsRunningSomewhere did NOT fire at all while our engine was running.")
        print("  → This path is DEAD for detecting external-app exit pre-Sonoma.")
        print("  → Consider: process-list polling or TCC/privacy event alternatives.")
    }

    if irFires > 0 {
        print("")
        print("  NOTE: IsRunning (process-scoped) fired \(irFires) time(s) — unexpected,")
        print("  suggests the HAL counts per-client and notifies on any client change.")
    }

    // Cleanup.
    removeRunningSomewhere()
    removeIsRunning()
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()

    print("")
    print("  Done.")

} catch {
    print("ERROR: \(error)")
    exit(1)
}
