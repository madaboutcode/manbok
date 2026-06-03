import CoreAudio
import Foundation

// Spike: can we observe macOS default input device changes in real time?
// Run: swift run device-spike [seconds]
// While running: change Sound → Input, plug/unplug headphones, switch AirPods.

private func defaultInputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}

private func deviceLabel(_ deviceID: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &unmanaged)
    if status == noErr, let cf = unmanaged?.takeRetainedValue() {
        return cf as String
    }

    address.mSelector = kAudioDevicePropertyDeviceUID
    var uid: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let uidStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
    if uidStatus == noErr, let cf = uid?.takeRetainedValue() {
        return cf as String
    }
    return "device #\(deviceID)"
}

private final class ListenerBox {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
}

private let listenerCallback: AudioObjectPropertyListenerProc = { _, _, _, context in
    guard let context else { return noErr }
    let box = Unmanaged<ListenerBox>.fromOpaque(context).takeUnretainedValue()
    box.handler()
    return noErr
}

private func runObserver(seconds: TimeInterval) {
    guard let initial = defaultInputDeviceID() else {
        print("no default input device")
        exit(1)
    }

    var lastID = initial
    print("watching default input (\(Int(seconds))s) — change mic in System Settings or plug/unplug headphones")
    print("  current: \(deviceLabel(initial)) [id=\(initial)]")

    let box = ListenerBox {
        guard let newID = defaultInputDeviceID() else { return }
        guard newID != lastID else { return }
        let oldLabel = deviceLabel(lastID)
        let newLabel = deviceLabel(newID)
        print("  CHANGED: \(oldLabel) → \(newLabel) [id \(lastID)→\(newID)]")
        lastID = newID
    }

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let selfPtr = Unmanaged.passRetained(box).toOpaque()
    defer { Unmanaged<ListenerBox>.fromOpaque(selfPtr).release() }

    var addStatus = AudioObjectAddPropertyListener(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        listenerCallback,
        selfPtr
    )
    guard addStatus == noErr else {
        print("AudioObjectAddPropertyListener failed: \(addStatus)")
        exit(1)
    }
    defer {
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerCallback,
            selfPtr
        )
    }

    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    print("done.")
}

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "30") ?? 30
runObserver(seconds: seconds)