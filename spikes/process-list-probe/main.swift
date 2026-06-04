// Build: swiftc main.swift -framework CoreAudio -framework CoreFoundation -o probe
// Run:   ./probe
//
// Spike: Non-destructive mic-usage detection via kAudioHardwarePropertyProcessObjectList
// (macOS Sonoma / HAL AudioProcess objects, available macOS 14+)
//
// Watches for 60 seconds. Start/stop Zoom, FaceTime, or any mic-using app to observe.

import CoreAudio
import CoreFoundation
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Helpers
// ─────────────────────────────────────────────────────────────────────────────

func timestamp() -> String {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss.SSS"
    return df.string(from: Date())
}

func log(_ msg: String) {
    print("[\(timestamp())] \(msg)")
    fflush(stdout)
}

func selectorName(_ sel: AudioObjectPropertySelector) -> String {
    let bytes = withUnsafeBytes(of: sel.bigEndian) { Array($0) }
    let chars = bytes.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : Character("?") }
    return "'\(String(chars))'"
}

/// Read a scalar UInt32 property from a CoreAudio object.
func readUInt32(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    if status != noErr {
        log("  WARN: readUInt32 obj=\(objectID) sel=\(selectorName(selector)) failed: OSStatus \(status)")
        return nil
    }
    return value
}

/// Read a pid_t property.
func readPID(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> pid_t? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    if status != noErr {
        log("  WARN: readPID obj=\(objectID) sel=\(selectorName(selector)) failed: OSStatus \(status)")
        return nil
    }
    return value
}

/// Read a CFString property (retained).
func readCFString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &unmanaged)
    if status != noErr {
        log("  WARN: readCFString obj=\(objectID) sel=\(selectorName(selector)) failed: OSStatus \(status)")
        return nil
    }
    guard let cf = unmanaged?.takeRetainedValue() else {
        log("  WARN: readCFString obj=\(objectID) sel=\(selectorName(selector)) returned nil CFString")
        return nil
    }
    return cf as String
}

/// Read an array of AudioObjectIDs.
func readObjectIDs(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size)
    if sizeStatus != noErr {
        log("  WARN: readObjectIDs size obj=\(objectID) sel=\(selectorName(selector)) failed: OSStatus \(sizeStatus)")
        return []
    }
    if size == 0 { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ids)
    if status != noErr {
        log("  WARN: readObjectIDs data obj=\(objectID) sel=\(selectorName(selector)) failed: OSStatus \(status)")
        return []
    }
    return ids
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Process snapshot
// ─────────────────────────────────────────────────────────────────────────────

struct ProcessInfo: Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunning: Bool
    let isRunningInput: Bool
    let deviceIDs: [AudioObjectID]
}

func snapshotProcesses(excludingPID ownPID: pid_t) -> [AudioObjectID: ProcessInfo] {
    // All selectors use the named SDK constants (macOS 14+ / Sonoma).
    // Verified against AudioHardware.h:
    //   kAudioHardwarePropertyProcessObjectList = 'prs#'
    //   kAudioProcessPropertyPID                = 'ppid'
    //   kAudioProcessPropertyBundleID           = 'pbid'
    //   kAudioProcessPropertyIsRunning          = 'pir?'
    //   kAudioProcessPropertyIsRunningInput     = 'piri'
    //   kAudioProcessPropertyDevices            = 'pdv#'
    let processIDs = readObjectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    var result: [AudioObjectID: ProcessInfo] = [:]

    for objID in processIDs {
        guard let pid = readPID(objID, kAudioProcessPropertyPID), pid != ownPID else { continue }
        let bundleID = readCFString(objID, kAudioProcessPropertyBundleID) ?? "<unknown>"
        let isRunning = (readUInt32(objID, kAudioProcessPropertyIsRunning) ?? 0) != 0
        let isRunningInput = (readUInt32(objID, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
        let devices = readObjectIDs(objID, kAudioProcessPropertyDevices)
        result[objID] = ProcessInfo(objectID: objID, pid: pid, bundleID: bundleID,
                                    isRunning: isRunning, isRunningInput: isRunningInput,
                                    deviceIDs: devices)
    }
    return result
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Print table
// ─────────────────────────────────────────────────────────────────────────────

func printTable(_ procs: [AudioObjectID: ProcessInfo]) {
    func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
    print("\(pad("PID", 8)) \(pad("Bundle ID", 50)) \(pad("IsRunning", 10)) \(pad("IsRunInput", 14)) Devices")
    print(String(repeating: "-", count: 100))
    fflush(stdout)
    for info in procs.values.sorted(by: { $0.pid < $1.pid }) {
        let devStr = info.deviceIDs.map { String($0) }.joined(separator: ",")
        print("\(pad(String(info.pid), 8)) \(pad(info.bundleID, 50)) \(pad(info.isRunning ? "YES" : "NO", 10)) \(pad(info.isRunningInput ? "YES" : "NO", 14)) \(devStr.isEmpty ? "-" : devStr)")
        fflush(stdout)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Listeners
// ─────────────────────────────────────────────────────────────────────────────

// Tracks registered listener block tokens so we can remove them on exit.
var listenerRemovers: [() -> Void] = []

/// Register an AudioObjectAddPropertyListenerBlock on a process object for IsRunningInput.
func registerIsRunningInputListener(for info: ProcessInfo) {
    let pid = info.pid
    let bundleID = info.bundleID
    let objID = info.objectID

    let block: AudioObjectPropertyListenerBlock = { _, _ in
        let isRunningInput = (readUInt32(objID, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
        log("[LISTENER] pid=\(pid) (\(bundleID)) IsRunningInput changed → \(isRunningInput ? "YES (MIC ACTIVE)" : "NO (mic idle)")")
    }

    var addAddr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectAddPropertyListenerBlock(objID, &addAddr, DispatchQueue.main, block)
    if status == noErr {
        listenerRemovers.append {
            var rmAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(objID, &rmAddr, DispatchQueue.main, block)
        }
        log("  Registered IsRunningInput listener for pid=\(pid) (\(bundleID))")
    } else {
        log("  WARNING: Could not register listener for pid=\(pid): OSStatus \(status)")
    }
}

/// Register a listener on kAudioHardwarePropertyProcessObjectList to detect new/removed processes.
func registerProcessListListener(ownPID: pid_t) {
    let block: AudioObjectPropertyListenerBlock = { _, _ in
        let current = snapshotProcesses(excludingPID: ownPID)
        log("[LISTENER] ProcessObjectList changed. Current count: \(current.count)")
        for info in current.values.sorted(by: { $0.pid < $1.pid }) {
            log("  pid=\(info.pid) (\(info.bundleID)) isRunningInput=\(info.isRunningInput ? "YES" : "NO")")
        }
    }

    var addAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &addAddr, DispatchQueue.main, block
    )
    if status == noErr {
        listenerRemovers.append {
            var rmAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &rmAddr, DispatchQueue.main, block
            )
        }
        log("Registered ProcessObjectList change listener on SystemObject")
    } else {
        log("WARNING: Could not register ProcessObjectList listener: OSStatus \(status)")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Poll loop
// ─────────────────────────────────────────────────────────────────────────────

var previousSnapshot: [AudioObjectID: ProcessInfo] = [:]

func poll(ownPID: pid_t) {
    let current = snapshotProcesses(excludingPID: ownPID)
    var changed = false

    // Detect new processes
    for (objID, info) in current {
        if previousSnapshot[objID] == nil {
            log("[POLL] New process: pid=\(info.pid) (\(info.bundleID)) isRunningInput=\(info.isRunningInput ? "YES" : "NO")")
            changed = true
        }
    }

    // Detect removed processes
    for (objID, info) in previousSnapshot {
        if current[objID] == nil {
            log("[POLL] Removed process: pid=\(info.pid) (\(info.bundleID))")
            changed = true
        }
    }

    // Detect state changes
    for (objID, info) in current {
        guard let prev = previousSnapshot[objID] else { continue }
        if info.isRunning != prev.isRunning {
            log("[POLL] pid=\(info.pid) (\(info.bundleID)) IsRunning: \(prev.isRunning ? "YES" : "NO") → \(info.isRunning ? "YES" : "NO")")
            changed = true
        }
        if info.isRunningInput != prev.isRunningInput {
            log("[POLL] pid=\(info.pid) (\(info.bundleID)) IsRunningInput: \(prev.isRunningInput ? "YES" : "NO") → \(info.isRunningInput ? "YES" : "NO")")
            changed = true
        }
    }

    if !changed {
        log("[POLL] No changes. \(current.count) process(es) tracked.")
    }

    previousSnapshot = current
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Main
// ─────────────────────────────────────────────────────────────────────────────

let ownPID = getpid()
log("Probe started. Own PID: \(ownPID). Watching for 60 seconds.")
log("Start/stop Zoom, FaceTime, or any mic-using app to observe listeners and poll changes.")
print("")

// Initial snapshot
let initial = snapshotProcesses(excludingPID: ownPID)
previousSnapshot = initial

log("Initial process table (\(initial.count) audio process(es) excluding self):")
printTable(initial)
print("")

// Register per-process IsRunningInput listeners
log("Registering per-process IsRunningInput listeners...")
for info in initial.values {
    registerIsRunningInputListener(for: info)
}

// Register system-level ProcessObjectList listener
registerProcessListListener(ownPID: ownPID)
print("")

// Poll every 2 seconds using a repeating timer on the main run loop
var tickCount = 0
let totalTicks = 30  // 30 × 2s = 60s

let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
timer.schedule(deadline: .now() + 2, repeating: 2.0)
timer.setEventHandler {
    tickCount += 1
    poll(ownPID: ownPID)
    if tickCount >= totalTicks {
        log("60 seconds elapsed. Cleaning up listeners and exiting.")
        for remove in listenerRemovers { remove() }
        exit(0)
    }
}
timer.resume()

// Run the main run loop (required for AudioObjectAddPropertyListenerBlock callbacks)
RunLoop.main.run()
