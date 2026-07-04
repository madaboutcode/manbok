// Spike: diagnose why manbok daemon never transitions from watching → capturing.
//
// Tests three hypotheses:
//   H1: App (e.g. Pipit) never sets IsRunningInput=true in CoreAudio HAL
//   H2: IsRunningInput flickers too briefly for 500ms poll to catch
//   H3: HAL state goes stale after sleep/wake
//
// Uses the SAME CoreAudio HAL APIs as ProcessAudioMonitor in ManbokPlatform.
// Polls at 100ms (5x faster than daemon's 500ms) to catch brief flickers.
// Also registers HAL listeners for IsRunningInput changes.
//
// Usage:
//   cd spikes && swift run mic-detect-spike [seconds]
//   Start/stop Pipit (or any mic app) while this runs.

import CoreAudio
import CoreFoundation
import Foundation

// MARK: - HAL helpers (identical to ProcessAudioMonitor)

func readUInt32(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

func readPID(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> pid_t? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

func readCFString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ref)
    guard status == noErr, let cf = ref?.takeRetainedValue() else { return nil }
    return cf as String
}

func readObjectIDs(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

// MARK: - Timestamp

func ts() -> String {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss.SSS"
    return df.string(from: Date())
}

func emit(_ msg: String) {
    print("[\(ts())] \(msg)")
    fflush(stdout)
}

// MARK: - alwaysOnProcesses (same as ProcessAudioMonitor)

let alwaysOnProcesses: Set<String> = [
    "com.apple.CoreSpeech",
    "com.apple.SiriNCService",
    "com.apple.accessibility.heard",
    "com.apple.cmio.ContinuityCaptureAgent",
]

// MARK: - Snapshot matching daemon's otherInputProcesses()

struct ProcEntry: Equatable {
    let objID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningInput: Bool
}

func otherInputProcesses(ownPID: pid_t) -> [ProcEntry] {
    let processIDs = readObjectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    var result: [ProcEntry] = []
    for objID in processIDs {
        guard let pid = readPID(objID, kAudioProcessPropertyPID), pid != ownPID else { continue }
        let isRunningInput = (readUInt32(objID, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
        let bundleID = readCFString(objID, kAudioProcessPropertyBundleID) ?? ""
        result.append(ProcEntry(objID: objID, pid: pid, bundleID: bundleID, isRunningInput: isRunningInput))
    }
    return result
}

func filteredInputProcesses(ownPID: pid_t) -> [ProcEntry] {
    otherInputProcesses(ownPID: ownPID).filter { $0.isRunningInput && !alwaysOnProcesses.contains($0.bundleID) }
}

// MARK: - Listener registration

var listenerRemovers: [() -> Void] = []

func registerIsRunningInputListener(objID: AudioObjectID, pid: pid_t, bundleID: String) {
    let block: AudioObjectPropertyListenerBlock = { _, _ in
        let val = (readUInt32(objID, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
        emit("🔔 LISTENER pid=\(pid) (\(bundleID)) IsRunningInput → \(val ? "YES ✅" : "NO")")
    }
    var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectAddPropertyListenerBlock(objID, &addr, DispatchQueue.main, block)
    if status == noErr {
        listenerRemovers.append {
            var rmAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(objID, &rmAddr, DispatchQueue.main, block)
        }
    }
}

// MARK: - Main

let ownPID = getpid()
let duration = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 120 : 120

emit("=== mic-detect-spike ===")
emit("Own PID: \(ownPID)")
emit("Duration: \(duration)s")
emit("Poll interval: 100ms (daemon uses 500ms)")
emit("")
emit("This spike uses the SAME HAL APIs as ProcessAudioMonitor.")
emit("Start/stop Pipit or any mic app while this runs.")
emit("")

// Initial snapshot — show all processes
let allProcs = otherInputProcesses(ownPID: ownPID)
let pipitProcs = allProcs.filter { $0.bundleID.lowercased().contains("pipit") }
let inputActive = allProcs.filter { $0.isRunningInput }

emit("--- Initial state ---")
emit("Total HAL audio processes: \(allProcs.count)")
emit("With IsRunningInput=YES: \(inputActive.count)")
if !inputActive.isEmpty {
    for p in inputActive {
        emit("  ✅ pid=\(p.pid) \(p.bundleID) (filtered=\(!alwaysOnProcesses.contains(p.bundleID)))")
    }
}
if !pipitProcs.isEmpty {
    for p in pipitProcs {
        emit("  🔍 Pipit: pid=\(p.pid) objID=\(p.objID) IsRunningInput=\(p.isRunningInput ? "YES" : "NO")")
    }
} else {
    emit("  ⚠️  Pipit NOT in HAL process list")
}

// What daemon would see
let daemonView = filteredInputProcesses(ownPID: ownPID)
emit("")
emit("Daemon's view (otherInputProcesses minus alwaysOn): \(daemonView.count) process(es)")
for p in daemonView {
    emit("  → pid=\(p.pid) \(p.bundleID)")
}
if daemonView.isEmpty {
    emit("  → EMPTY — daemon would stay in 'watching' phase")
}

// Register listeners on ALL processes (not just input-active ones)
emit("")
emit("Registering IsRunningInput listeners on all \(allProcs.count) processes...")
for p in allProcs {
    registerIsRunningInputListener(objID: p.objID, pid: p.pid, bundleID: p.bundleID)
}

// Also listen for new processes joining
let sysListenerBlock: AudioObjectPropertyListenerBlock = { _, _ in
    let current = otherInputProcesses(ownPID: ownPID)
    let newPipit = current.filter { $0.bundleID.lowercased().contains("pipit") }
    let newInput = current.filter { $0.isRunningInput && !alwaysOnProcesses.contains($0.bundleID) }
    emit("🔔 ProcessList changed — \(current.count) procs, \(newInput.count) with input active")
    if !newPipit.isEmpty {
        for p in newPipit {
            emit("  🔍 Pipit: pid=\(p.pid) IsRunningInput=\(p.isRunningInput ? "YES ✅" : "NO")")
        }
    }
    // Register listeners on any new processes
    for p in current {
        registerIsRunningInputListener(objID: p.objID, pid: p.pid, bundleID: p.bundleID)
    }
}
var sysAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &sysAddr, DispatchQueue.main, sysListenerBlock)
listenerRemovers.append {
    var rmAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &rmAddr, DispatchQueue.main, sysListenerBlock)
}

// MARK: - High-frequency poll (100ms) to catch flickers

emit("")
emit("--- Polling at 100ms (Ctrl-C to stop) ---")
emit("")

var prevInputPIDs: Set<pid_t> = Set(inputActive.map(\.pid))
var flickerCount = 0
var tickCount = 0
let totalTicks = duration * 10  // 100ms intervals

let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
timer.setEventHandler {
    tickCount += 1

    let current = otherInputProcesses(ownPID: ownPID)
    let currentInput = current.filter { $0.isRunningInput && !alwaysOnProcesses.contains($0.bundleID) }
    let currentInputPIDs = Set(currentInput.map(\.pid))

    let appeared = currentInputPIDs.subtracting(prevInputPIDs)
    let disappeared = prevInputPIDs.subtracting(currentInputPIDs)

    if !appeared.isEmpty {
        for pid in appeared {
            let info = currentInput.first { $0.pid == pid }
            emit("▶️  INPUT ACTIVE  pid=\(pid) \(info?.bundleID ?? "?") — daemon WOULD trigger capture")
        }
    }
    if !disappeared.isEmpty {
        for pid in disappeared {
            emit("⏹️  INPUT STOPPED pid=\(pid)")
        }
    }

    // Detect flicker: appeared and disappeared within ~500ms (5 ticks)
    if !appeared.isEmpty {
        flickerCount = 5
    }
    if flickerCount > 0 {
        flickerCount -= 1
        if !disappeared.isEmpty && flickerCount > 0 {
            emit("⚡ FLICKER DETECTED — input appeared and disappeared within <500ms")
            emit("   This would be MISSED by the daemon's 500ms poll interval (confirms H2)")
        }
    }

    // Periodic heartbeat every 10s
    if tickCount % 100 == 0 {
        let pipit = current.filter { $0.bundleID.lowercased().contains("pipit") }
        let pipitStatus = pipit.isEmpty ? "not in HAL" : pipit.map { "IsRunningInput=\($0.isRunningInput ? "YES" : "NO")" }.joined()
        emit("💓 \(tickCount/10)s elapsed — \(currentInput.count) active input proc(s), Pipit: \(pipitStatus)")
    }

    prevInputPIDs = currentInputPIDs

    if tickCount >= totalTicks {
        emit("")
        emit("=== Done (\(duration)s). Cleaning up. ===")
        for remove in listenerRemovers { remove() }
        exit(0)
    }
}
timer.resume()

RunLoop.main.run()
