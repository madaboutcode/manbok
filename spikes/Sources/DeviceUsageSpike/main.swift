import CoreAudio
import Foundation

// Spike: can we tell if the default INPUT has active IO (mic "in use") from *some* client?
// And can we distinguish "only us" vs "someone else" by comparing while idle vs while we hold IO?
//
// Run: swift run device-usage-spike
// Then: with spike NOT capturing, open Voice Memos / Zoom and record — watch isRunningSomewhere.
// Compare to: run capture-spike in another terminal — see if flag differs.

private func defaultInputID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
          id != kAudioObjectUnknown else { return nil }
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

private func uint32Property(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> (Bool, UInt32) {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    return (status == noErr, value)
}

private func poll(deviceID: AudioDeviceID, label: String) {
    let (runOk, running) = uint32Property(deviceID, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
    let (ioOk, ioRunning) = uint32Property(deviceID, selector: kAudioDevicePropertyDeviceIsRunning)
    print(
        "[\(label)] runningSomewhere=\(runOk ? String(running) : "?") " +
        "deviceIsRunning=\(ioOk ? String(ioRunning) : "?")"
    )
}

guard let deviceID = defaultInputID() else {
    print("no default input")
    exit(1)
}

print("default input: \(deviceName(deviceID)) [id=\(deviceID)]")
print("Poll every 1s for 20s — start/stop recording in another app while this runs.")
print("(We are NOT opening the mic ourselves in this spike.)\n")

for i in 0..<20 {
    poll(deviceID: deviceID, label: String(format: "%2ds", i))
    Thread.sleep(forTimeInterval: 1)
}
print("\nIf runningSomewhere stays 0 until you record elsewhere, we can use it as 'mic busy' signal.")
print("Per-app identity (Zoom vs Meet) is NOT available here — only device-level IO.")