import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

// Spike: instrumented harness to observe exactly what signals fire and what an AVAudioEngine
// input tap does across input-device-change scenarios.
//
// Incident this spike investigates: AVAudioEngine tap froze when a Bluetooth headset was
// turned off mid-capture — the tap delivered no more callbacks and nothing observed it.
//
// Run: cd spikes && swift run device-switch-spike [seconds] [--auto-restart] [--device <substring>]
//
// Scenarios (run manually, one per invocation):
//   S1: change default input in System Settings > Sound (both devices present)
//   S2: turn OFF the active Bluetooth headset mid-run (the incident scenario)
//   S3: reconnect Bluetooth mid-run (arrival + auto-switch)
//   S4: switch the mic INSIDE a meeting app (Meet/Zoom) mid-run and watch the pdv# lines

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

// MARK: - HAL helpers (pattern copied from MicDetectSpike; scope is a parameter here
// because kAudioProcessPropertyDevices ('pdv#') requires Input/Output scope to select
// which device list comes back — see AudioHardware.h doc comment).

private func readUInt32(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> UInt32? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    return status == noErr ? value : nil
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

// MARK: - Device helpers (pattern copied from DeviceCaptureSpike / DeviceUsageSpike)

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

// MARK: - RMS

/// Converts a linear RMS amplitude (0...1) to dBFS, floored at -120 for silence/zero.
private func dbfs(fromRMS rms: Float) -> Float {
    guard rms > 0 else { return -120 }
    let db = 20 * log10(rms)
    return max(db, -120)
}

// MARK: - Tap accumulator

/// Accumulates per-second stats from the tap callback. Not thread-safe beyond a simple lock —
/// tap callbacks land on the audio I/O thread, the summary printer runs on the main thread.
private final class TapStats {
    private let lock = NSLock()
    private var callbackCount = 0
    private var frameCount: UInt64 = 0
    private var sumSquares: Double = 0
    private var sampleCount: Int = 0
    private(set) var lastCallbackAt: Date?
    private(set) var lastFormat: AVAudioFormat?

    func record(buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        callbackCount += 1
        frameCount += UInt64(buffer.frameLength)
        lastCallbackAt = Date()
        lastFormat = buffer.format

        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        for ch in 0..<channels {
            let ptr = channelData[ch]
            for i in 0..<frames {
                let s = Double(ptr[i])
                sumSquares += s * s
            }
        }
        sampleCount += frames * channels
    }

    /// Snapshot-and-reset for the once-per-second summary line.
    func drainSecond() -> (callbacks: Int, frames: UInt64, rmsDbfs: Float, format: AVAudioFormat?) {
        lock.lock()
        defer {
            callbackCount = 0
            sumSquares = 0
            sampleCount = 0
            lock.unlock()
        }
        let rms: Float
        if sampleCount > 0 {
            rms = Float(sqrt(sumSquares / Double(sampleCount)))
        } else {
            rms = 0
        }
        return (callbackCount, frameCount, dbfs(fromRMS: rms), lastFormat)
    }

    func timeSinceLastCallback() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastCallbackAt else { return nil }
        return Date().timeIntervalSince(last)
    }

    func resetCallbackClock() {
        lock.lock()
        defer { lock.unlock() }
        lastCallbackAt = nil
    }

    func waitForFirstCallback(timeout: TimeInterval) -> TimeInterval? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            lock.lock()
            let got = lastCallbackAt
            lock.unlock()
            if let got {
                return got.timeIntervalSince(start)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }
}

// MARK: - Engine wrapper

private enum PinError: Error, CustomStringConvertible {
    case noMatchingDevice(String)
    case audioUnitNil
    case setPropertyFailed(OSStatus)
    case hwFormatUnavailable

    var description: String {
        switch self {
        case .noMatchingDevice(let s): return "no input device name contains '\(s)'"
        case .audioUnitNil: return "inputNode.audioUnit is nil — cannot pin device"
        case .setPropertyFailed(let status): return "AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice) failed: \(status)"
        case .hwFormatUnavailable: return "input HW format is 0 Hz — no usable input (device gone or mic permission missing)"
        }
    }
}

/// Wraps a fresh AVAudioEngine + input tap, mirroring AVAudioCapture's engine-per-session pattern
/// (see Sources/ManbokPlatform/Capture/AVAudioCapture.swift). No format conversion here — raw tap
/// observation is enough for this spike.
private final class EngineHarness {
    private(set) var engine: AVAudioEngine?
    let stats = TapStats()
    private let pinnedDeviceID: AudioDeviceID?

    init(pinnedDeviceID: AudioDeviceID?) {
        self.pinnedDeviceID = pinnedDeviceID
    }

    func start() throws {
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode

        if let pinnedDeviceID {
            try pin(input: input, to: pinnedDeviceID)
        }

        // inputFormat(forBus:) reflects the actual HW device — outputFormat(forBus:) can be
        // stale after pinning a device on the input AU ("Input HW format and tap format not
        // matching" crash). 0 Hz means no usable input (e.g. no mic permission).
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw PinError.hwFormatUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [stats] buffer, _ in
            stats.record(buffer: buffer)
        }

        try newEngine.start()
        engine = newEngine
        emit("engine started, format=\(format.sampleRate)Hz/\(format.channelCount)ch")
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func pin(input: AVAudioInputNode, to deviceID: AudioDeviceID) throws {
        guard let audioUnit = input.audioUnit else {
            throw PinError.audioUnitNil
        }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw PinError.setPropertyFailed(status)
        }
        emit("pinned input to \(deviceLabel(deviceID))")
    }
}

// MARK: - pdv# (process input-device mapping) probe

private struct ProcessDeviceMapping: Equatable {
    let bundleID: String
    let deviceLabels: [String]
}

private func probeProcessInputDevices(ownPID: pid_t) -> [pid_t: ProcessDeviceMapping] {
    let (processIDs, listStatus) = readObjectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    if listStatus != noErr {
        emit("!! pdv# probe: failed to read process object list, status=\(listStatus)")
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
            emit("!! pdv#: \(bundleID) — AudioObjectGetPropertyData(kAudioProcessPropertyDevices, scope=Input) failed, status=\(status)")
            continue
        }
        let labels = deviceIDs.map { deviceLabel($0) }
        result[pid] = ProcessDeviceMapping(bundleID: bundleID, deviceLabels: labels)
    }
    return result
}

// MARK: - CLI args

private struct Args {
    var duration: Double = 120
    var autoRestart = false
    var deviceSubstring: String?
}

private func parseArgs() -> Args {
    var args = Args()
    let rest = Array(CommandLine.arguments.dropFirst())
    var positionalConsumed = false
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--auto-restart":
            args.autoRestart = true
        case "--device":
            guard i + 1 < rest.count else {
                emit("!! --device requires a value")
                exit(1)
            }
            args.deviceSubstring = rest[i + 1]
            i += 1
        default:
            if !positionalConsumed, let d = Double(rest[i]) {
                args.duration = d
                positionalConsumed = true
            }
        }
        i += 1
    }
    return args
}

// MARK: - Main

emit("=== device-switch-spike ===")
let ownPID = getpid()
private let args = parseArgs()
emit("pid=\(ownPID) duration=\(Int(args.duration))s autoRestart=\(args.autoRestart) device=\(args.deviceSubstring ?? "(default)")")
print("")
print("SCENARIO CHECKLIST (run one per invocation):")
print("  S1: change default input in System Settings > Sound (both devices present)")
print("  S2: turn OFF the active Bluetooth headset mid-run (the incident scenario)")
print("  S3: reconnect Bluetooth mid-run (arrival + auto-switch)")
print("  S4: switch the mic INSIDE a meeting app (Meet/Zoom) mid-run and watch the pdv# lines")
print("")

switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    break
case .notDetermined:
    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { _ in sem.signal() }
    sem.wait()
default:
    emit("!! microphone not authorized — grant access and re-run")
    exit(1)
}

var pinnedDeviceID: AudioDeviceID?
if let substring = args.deviceSubstring {
    let matches = inputDeviceIDs().filter { deviceName($0).lowercased().contains(substring.lowercased()) }
    guard let match = matches.first else {
        emit("!! \(PinError.noMatchingDevice(substring))")
        exit(1)
    }
    pinnedDeviceID = match
    emit("resolved --device '\(substring)' -> \(deviceLabel(match))")
}

private var harness = EngineHarness(pinnedDeviceID: pinnedDeviceID)
do {
    try harness.start()
} catch {
    emit("!! initial engine start failed: \(error)")
    exit(1)
}

// MARK: Device-list snapshot for observer (c)

private func snapshotDeviceList() -> [AudioDeviceID: (name: String, hasInput: Bool)] {
    var snap: [AudioDeviceID: (String, Bool)] = [:]
    for id in allDeviceIDs() {
        snap[id] = (deviceName(id), deviceHasInputStreams(id))
    }
    return snap
}

private var lastDeviceSnapshot = snapshotDeviceList()
private var lastProcessDeviceMap = probeProcessInputDevices(ownPID: ownPID)

// MARK: Restart coordination (shared between observers a/b)

let restartLock = NSLock()
var lastRestartRequestAt: Date?

private func requestRestart(reason: String) {
    guard args.autoRestart else { return }
    restartLock.lock()
    if let last = lastRestartRequestAt, Date().timeIntervalSince(last) < 1.0 {
        restartLock.unlock()
        emit("(debounced restart request: \(reason))")
        return
    }
    lastRestartRequestAt = Date()
    restartLock.unlock()

    DispatchQueue.main.async {
        emit(">> restart triggered by: \(reason)")
        let gapStart = harness.stats.timeSinceLastCallback()
        harness.stop()
        harness.stats.resetCallbackClock()
        let newHarness = EngineHarness(pinnedDeviceID: pinnedDeviceID)
        do {
            try newHarness.start()
            harness = newHarness
            if let gap = newHarness.stats.waitForFirstCallback(timeout: 5) {
                let totalGap = (gapStart ?? 0) + gap
                emit(">> restart: gap=\(String(format: "%.2f", totalGap))s (stall-before-restart=\(String(format: "%.2f", gapStart ?? 0))s + restart-to-first-callback=\(String(format: "%.2f", gap))s)")
            } else {
                emit(">> restart: WARNING no callback within 5s of restart")
            }
        } catch {
            emit(">> restart FAILED: \(error)")
        }
    }
}

// MARK: Observer (a) — AVAudioEngineConfigurationChange

let configChangeObserver = NotificationCenter.default.addObserver(
    forName: .AVAudioEngineConfigurationChange,
    object: nil,
    queue: .main
) { note in
    let running = (note.object as? AVAudioEngine)?.isRunning ?? harness.engine?.isRunning ?? false
    emit("!! AVAudioEngineConfigurationChange (engine.isRunning=\(running))")
    requestRestart(reason: "AVAudioEngineConfigurationChange")
}

// MARK: Observer (b) — default input device changed

var defaultInputListenerAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var lastKnownDefaultInput = defaultInputID()
let defaultInputListenerBlock: AudioObjectPropertyListenerBlock = { _, _ in
    let newID = defaultInputID()
    let oldLabel = lastKnownDefaultInput.map { deviceLabel($0) } ?? "unknown"
    let newLabel = newID.map { deviceLabel($0) } ?? "unknown"
    emit("!! default input changed: \(oldLabel) -> \(newLabel)")
    lastKnownDefaultInput = newID
    requestRestart(reason: "default input changed")
}
AudioObjectAddPropertyListenerBlock(
    AudioObjectID(kAudioObjectSystemObject), &defaultInputListenerAddr, DispatchQueue.main, defaultInputListenerBlock
)

// MARK: Observer (c) — device list changed

var deviceListAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
let deviceListListenerBlock: AudioObjectPropertyListenerBlock = { _, _ in
    let current = snapshotDeviceList()
    let addedIDs = Set(current.keys).subtracting(lastDeviceSnapshot.keys)
    let removedIDs = Set(lastDeviceSnapshot.keys).subtracting(current.keys)
    let addedDesc = addedIDs.map { id -> String in
        let info = current[id]!
        return "\(info.name) (\(id), hasInput=\(info.hasInput))"
    }
    let removedDesc = removedIDs.map { id -> String in
        let info = lastDeviceSnapshot[id]!
        return "\(info.name) (\(id), hasInput=\(info.hasInput))"
    }
    emit("!! device list changed: added=\(addedDesc) removed=\(removedDesc)")
    lastDeviceSnapshot = current
}
AudioObjectAddPropertyListenerBlock(
    AudioObjectID(kAudioObjectSystemObject), &deviceListAddr, DispatchQueue.main, deviceListListenerBlock
)

// MARK: Timers — 1s summary + 1s pdv# poll, driven from RunLoop.main

let startTime = Date()
var elapsedSeconds = 0

let summaryTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
summaryTimer.schedule(deadline: .now() + 1, repeating: 1)
summaryTimer.setEventHandler {
    elapsedSeconds += 1
    let (callbacks, frames, rms, format) = harness.stats.drainSecond()
    let running = harness.engine?.isRunning ?? false
    let fmtDesc = format.map { "\(Int($0.sampleRate))Hz/\($0.channelCount)ch" } ?? "?"
    let currentDefault = defaultInputID().map { deviceLabel($0) } ?? "unknown"
    emit("[t=\(elapsedSeconds)s] callbacks=\(callbacks) frames=\(frames) rms=\(String(format: "%.1f", rms))dBFS fmt=\(fmtDesc) engineRunning=\(running) device=\(currentDefault)")

    // Watchdog: signals alone are insufficient — a config-change storm at engine start was
    // observed where the debounce swallowed the terminal stop event and no further signal
    // ever arrived. Byte flow is the ground truth; restart whenever it stops.
    if args.autoRestart {
        let sinceLastCallback = harness.stats.timeSinceLastCallback() ?? .infinity
        if !running || sinceLastCallback > 2.0 {
            requestRestart(reason: "watchdog: engineRunning=\(running), \(String(format: "%.1f", min(sinceLastCallback, 999)))s since last callback")
        }
    }

    // pdv# probe, once per second (folded into the same timer per spec's "1-second poll").
    let currentMap = probeProcessInputDevices(ownPID: ownPID)
    for (pid, mapping) in currentMap {
        if lastProcessDeviceMap[pid] != mapping {
            emit("pdv#: \(mapping.bundleID) -> \(mapping.deviceLabels)")
        }
    }
    for pid in lastProcessDeviceMap.keys where currentMap[pid] == nil {
        emit("pdv#: \(lastProcessDeviceMap[pid]!.bundleID) -> [] (no longer running input)")
    }
    lastProcessDeviceMap = currentMap

    if elapsedSeconds >= Int(args.duration) {
        emit("=== done (\(Int(args.duration))s) — cleaning up ===")
        NotificationCenter.default.removeObserver(configChangeObserver)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInputListenerAddr, DispatchQueue.main, defaultInputListenerBlock)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceListAddr, DispatchQueue.main, deviceListListenerBlock)
        harness.stop()
        exit(0)
    }
}
summaryTimer.resume()

RunLoop.main.run()
