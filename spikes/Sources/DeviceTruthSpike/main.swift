import CoreAudio
import Foundation

// Spike: is device-level HAL metadata trustworthy enough to rank fallback capture candidates?
//
// Three hypotheses:
//   H-RUN:       kAudioDevicePropertyDeviceIsRunningSomewhere reads 1 on exactly the input
//                device(s) another app is actively recording from, and 0 on idle input devices.
//                Watch for always-on system holders (e.g. com.apple.CoreSpeech / "Hey Siri")
//                keeping the built-in mic permanently "running" — that would poison the signal.
//   H-TRANSPORT: kAudioDevicePropertyTransportType reliably distinguishes built-in vs Bluetooth
//                vs USB vs virtual/aggregate input devices.
//   H-MUTE:      which input devices expose kAudioDevicePropertyMute (input scope) at all, and
//                does its value track OS-level mute actions.
//
// Run: cd spikes && swift run device-truth-spike [seconds]   (default 60s, no mic permission needed
// — this spike never opens the mic, it only reads HAL device metadata.)
//
// Manual scenario script (run once per invocation):
//   1. Record in Voice Memos or QuickTime on the default mic, then stop.
//   2. Switch a call app (Zoom/Meet/FaceTime) to a DIFFERENT mic and record on that.
//   3. Toggle any mute affordances available (app mute button, hardware mute key, System
//      Settings input mute if present).
// Watch which columns change (Δ-prefixed rows) at each step, and cross-reference against the
// pdv# process→device map to see which app is actually holding which device.

// MARK: - Timestamp / logging

private func ts() -> String {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss.SSS"
    return df.string(from: Date())
}

private func emit(_ msg: String) {
    print("[\(ts())] \(msg)")
    fflush(stdout)
}

/// Renders an OSStatus as its four-char-code form when printable (e.g. most CoreAudio/AudioUnit
/// error codes are packed ASCII), falling back to the raw decimal value otherwise.
private func fourCC(_ status: OSStatus) -> String {
    let bytes: [UInt8] = [
        UInt8((status >> 24) & 0xff),
        UInt8((status >> 16) & 0xff),
        UInt8((status >> 8) & 0xff),
        UInt8(status & 0xff),
    ]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let s = String(bytes: bytes, encoding: .ascii) {
        return "'\(s)' (\(status))"
    }
    return "\(status)"
}

// MARK: - HAL helpers (copied from DeviceUsageSpike / PinnedCaptureSpike; scope is a parameter
// where a property can be read on a non-Global scope, e.g. kAudioProcessPropertyDevices needs
// Input/Output scope to select which device list comes back)

private func readUInt32(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> UInt32? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

private func readFloat32(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> Float32? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

private func hasProperty(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    return AudioObjectHasProperty(objectID, &addr)
}

private func readPID(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> pid_t? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

private func readCFString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ref)
    guard status == noErr, let cf = ref?.takeRetainedValue() else { return nil }
    return cf as String
}

private func readObjectIDs(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> ([AudioObjectID], OSStatus) {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size)
    guard sizeStatus == noErr else { return ([], sizeStatus) }
    guard size > 0 else { return ([], noErr) }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ids)
    return status == noErr ? (ids, noErr) : ([], status)
}

// MARK: - Device helpers (copied from DeviceUsageSpike / PinnedCaptureSpike)

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

private func deviceLabel(_ id: AudioDeviceID) -> String {
    "\(deviceName(id)) (\(id))"
}

private func allDeviceIDs() -> [AudioDeviceID] {
    let (ids, _) = readObjectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    return ids
}

private func deviceHasInputStreams(_ id: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
    return size > 0
}

private func inputDeviceIDs() -> [AudioDeviceID] {
    allDeviceIDs().filter { deviceHasInputStreams($0) }
}

// MARK: - Transport type decoding (H-TRANSPORT)

private func transportDescription(_ raw: UInt32) -> String {
    switch raw {
    case kAudioDeviceTransportTypeBuiltIn: return "builtin"
    case kAudioDeviceTransportTypeBluetooth: return "bt"
    case kAudioDeviceTransportTypeBluetoothLE: return "btle"
    case kAudioDeviceTransportTypeUSB: return "usb"
    case kAudioDeviceTransportTypeAggregate: return "aggregate"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    case kAudioDeviceTransportTypeContinuityCaptureWired: return "continuity"
    case kAudioDeviceTransportTypeContinuityCaptureWireless: return "continuity"
    case kAudioDeviceTransportTypeAirPlay: return "airplay"
    default: return fourCC(OSStatus(bitPattern: raw))
    }
}

/// Input-scope mute/volume can live on the master element or per-channel; probe in that order
/// (matches the pattern used in TestMicHarness's inputVolumeElement).
private func inputPropertyElement(
    _ id: AudioDeviceID,
    _ selector: AudioObjectPropertySelector
) -> AudioObjectPropertyElement? {
    for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
        if hasProperty(id, selector, scope: kAudioObjectPropertyScopeInput, element: element) {
            return element
        }
    }
    return nil
}

// MARK: - Per-device row (H-RUN / H-TRANSPORT / H-MUTE columns)

private struct DeviceRow: Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: String
    let isDefault: Bool
    let runningSomewhere: UInt32
    let isRunning: UInt32
    let mute: String
    let vol: String

    var line: String {
        "\(name) [\(id)] | transport=\(transport) | default=\(isDefault ? "Y" : "N") | " +
        "runningSomewhere=\(runningSomewhere) | isRunning=\(isRunning) | mute=\(mute) | vol=\(vol)"
    }
}

private func buildRow(_ id: AudioDeviceID, defaultInput: AudioDeviceID?) -> DeviceRow {
    let transportRaw = readUInt32(id, kAudioDevicePropertyTransportType) ?? 0
    let running = readUInt32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0
    let isRunning = readUInt32(id, kAudioDevicePropertyDeviceIsRunning) ?? 0

    let mute: String
    if let element = inputPropertyElement(id, kAudioDevicePropertyMute) {
        mute = (readUInt32(id, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput, element: element) ?? 0) == 0 ? "0" : "1"
    } else {
        mute = "n/a"
    }

    let vol: String
    if let element = inputPropertyElement(id, kAudioDevicePropertyVolumeScalar) {
        let v = readFloat32(id, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: element) ?? 0
        vol = String(format: "%.2f", v)
    } else {
        vol = "n/a"
    }

    return DeviceRow(
        id: id,
        name: deviceName(id),
        transport: transportDescription(transportRaw),
        isDefault: id == defaultInput,
        runningSomewhere: running,
        isRunning: isRunning,
        mute: mute,
        vol: vol
    )
}

private func snapshotRows() -> [AudioDeviceID: DeviceRow] {
    let defaultInput = defaultInputID()
    var rows: [AudioDeviceID: DeviceRow] = [:]
    for id in inputDeviceIDs() {
        rows[id] = buildRow(id, defaultInput: defaultInput)
    }
    return rows
}

private func orderedIDs(_ rows: [AudioDeviceID: DeviceRow]) -> [AudioDeviceID] {
    rows.keys.sorted { a, b in
        let na = rows[a]!.name
        let nb = rows[b]!.name
        return na == nb ? a < b : na < nb
    }
}

// MARK: - pdv# (process input-device mapping) probe (copied from PinnedCaptureSpike)

private struct ProcessDeviceMapping: Equatable {
    let bundleID: String
    let deviceLabels: [String]
}

private func probeProcessInputDevices(ownPID: pid_t) -> [pid_t: ProcessDeviceMapping] {
    let (processIDs, listStatus) = readObjectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    if listStatus != noErr {
        emit("!! pdv# probe: failed to read process object list, status=\(fourCC(listStatus))")
        return [:]
    }

    var result: [pid_t: ProcessDeviceMapping] = [:]
    for objID in processIDs {
        guard let pid = readPID(objID, kAudioProcessPropertyPID), pid != ownPID else { continue }
        let isRunningInput = (readUInt32(objID, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
        guard isRunningInput else { continue }

        let bundleID = readCFString(objID, kAudioProcessPropertyBundleID) ?? "pid:\(pid)"
        let (deviceIDs, status) = readObjectIDs(objID, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
        if status != noErr {
            emit("!! pdv#: \(bundleID) — AudioObjectGetPropertyData(kAudioProcessPropertyDevices, scope=Input) failed, status=\(fourCC(status))")
            continue
        }
        let labels = deviceIDs.map { deviceLabel($0) }
        result[pid] = ProcessDeviceMapping(bundleID: bundleID, deviceLabels: labels)
    }
    return result
}

// MARK: - Main

emit("=== device-truth-spike ===")
let ownPID = getpid()
let durationArg = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) : nil
let duration = durationArg ?? 60
emit("pid=\(ownPID) duration=\(duration)s (no mic permission needed — HAL metadata only)")
print("")
print("HYPOTHESES:")
print("  H-RUN:       runningSomewhere flips 0->1 only on the device actually being recorded from,")
print("               and back to 0 after stop. Watch for a device stuck at 1 the whole run —")
print("               check pdv# for an always-on holder (e.g. com.apple.CoreSpeech) explaining it.")
print("  H-TRANSPORT: transport decodes sensibly for every listed device (builtin/bt/btle/usb/")
print("               aggregate/virtual/continuity/airplay/raw fourcc).")
print("  H-MUTE:      observational — which devices expose kAudioDevicePropertyMute at all, and")
print("               whether its value tracks OS-level mute actions.")
print("")
print("MANUAL SCENARIO SCRIPT:")
print("  1. Record in Voice Memos/QuickTime on the default mic, then stop.")
print("  2. Switch a call app to a DIFFERENT mic and record on that.")
print("  3. Toggle any mute affordances available.")
print("  Watch which columns change (Δ-prefixed rows) at each step.")
print("")

private var lastRows = snapshotRows()
private var lastProcessMap = probeProcessInputDevices(ownPID: ownPID)

emit("== initial input device table (t=0s) ==")
for id in orderedIDs(lastRows) {
    emit(lastRows[id]!.line)
}
print("")

emit("== [initial pdv# process→device map] ==")
if lastProcessMap.isEmpty {
    emit("  (no processes currently running input)")
} else {
    for (_, mapping) in lastProcessMap {
        emit("pdv#: \(mapping.bundleID) -> \(mapping.deviceLabels)")
    }
}
print("")

var elapsedSeconds = 0
// Candidates for "stuck at runningSomewhere=1 the whole run": seeded from the initial table,
// pruned the moment a poll sees that device at 0. Whatever survives to the end never went to 0.
private var stuckRunningSomewhereCandidates: Set<AudioDeviceID> =
    Set(lastRows.filter { $0.value.runningSomewhere != 0 }.keys)

let pollTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
pollTimer.schedule(deadline: .now() + 1, repeating: 1)
pollTimer.setEventHandler {
    elapsedSeconds += 1

    let currentRows = snapshotRows()
    let currentIDs = Set(currentRows.keys)
    let lastIDs = Set(lastRows.keys)
    let addedIDs = currentIDs.subtracting(lastIDs)
    let removedIDs = lastIDs.subtracting(currentIDs)
    if !addedIDs.isEmpty || !removedIDs.isEmpty {
        let addedDesc = addedIDs.map { deviceLabel($0) }
        let removedDesc = removedIDs.map { deviceLabel($0) }
        emit("!! device list changed: added=\(addedDesc) removed=\(removedDesc)")
    }

    for id in orderedIDs(currentRows) {
        let row = currentRows[id]!
        if lastRows[id] != row {
            emit("Δ \(row.line)")
        }
        if row.runningSomewhere == 0 {
            stuckRunningSomewhereCandidates.remove(id)
        }
    }

    let currentMap = probeProcessInputDevices(ownPID: ownPID)
    for (pid, mapping) in currentMap {
        if lastProcessMap[pid] != mapping {
            emit("pdv#: \(mapping.bundleID) -> \(mapping.deviceLabels)")
        }
    }
    for pid in lastProcessMap.keys where currentMap[pid] == nil {
        emit("pdv#: \(lastProcessMap[pid]!.bundleID) -> [] (no longer running input)")
    }
    lastProcessMap = currentMap
    lastRows = currentRows

    if elapsedSeconds >= duration {
        emit("=== done (\(duration)s) ===")
        print("")
        print("WHAT TO LOOK FOR:")
        print("  PASS H-RUN if runningSomewhere flipped 0->1 only on the device recorded from, and")
        print("  back to 0 after stop. Devices that stayed at runningSomewhere=1 the entire run:")
        if stuckRunningSomewhereCandidates.isEmpty {
            print("    (none — no device was runningSomewhere=1 at every poll)")
        } else {
            for id in stuckRunningSomewhereCandidates.sorted() {
                let label = currentRows[id].map { "\($0.name) [\(id)]" } ?? "device \(id)"
                print("    - \(label) — check pdv# output above for the holder explaining this")
            }
        }
        print("  PASS H-TRANSPORT if every listed device decoded to a sensible transport (not a raw")
        print("  fourcc/number) — raw values above indicate an undecoded transport constant.")
        print("  H-MUTE is observational only: see which device rows showed mute=0/1 vs n/a above,")
        print("  and whether toggling mute during the run changed that column.")
        exit(0)
    }
}
pollTimer.resume()

RunLoop.main.run()
