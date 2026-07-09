import CoreAudio
import Foundation

// Spike: debug pdv# device resolution — two independent views, plus targeted
// instrumentation added after an adversarial review of the "Firefox never
// re-negotiates its open mic stream" theory (2026-07-09), then generalized to
// track multi-process apps (Chrome) after confirming Chrome's own audio-relevant
// helper processes can report any of three distinct bundle IDs.
//
// VIEW A (process → mic): current manbok approach.
//   For each HAL process with IsRunningInput=true, read its pdv# device list.
//
// VIEW B (mic → process): reverse lookup.
//   For each input device, check IsRunningSomewhere. If true, scan all process
//   objects to find which PIDs hold that device.
//
// INSTRUMENTATION ADDED DURING REVIEW:
//
// 1. FAST SAMPLING (0.2s, not 1s) — a decisive event ("session reclaimed" in
//    manbok's own log) happened within a ~1.4s window. 1s sampling can't
//    resolve that; 0.2s can.
//
// 2. RAW IsRunningInput TRANSITION LOG for a TRACKED PREFIX FAMILY (not a
//    single exact bundle ID — see below) — View A silently drops a process
//    from its list the instant IsRunningInput goes false, which looks
//    identical to "process still there but idle" unless the transition is
//    logged explicitly. This is the only way to tell "the app's own stream
//    flickered" apart from "manbok's poll view flickered."
//
// 3. TRACKING IS BY PREFIX, NOT EXACT BUNDLE ID, AND SUPPORTS MULTIPLE
//    SIMULTANEOUS PROCESSES. Reason: Google Chrome ships THREE distinct
//    bundle IDs that can plausibly be the one reporting IsRunningInput=true
//    for a WebRTC/getUserMedia capture:
//      com.google.Chrome                   (main browser process)
//      com.google.Chrome.helper.renderer   (per-tab renderer — where page JS runs)
//      com.google.Chrome.helper            (shared by BOTH the GPU process and
//                                            the Utility/audio-service process —
//                                            these two are indistinguishable from
//                                            kAudioProcessPropertyBundleID alone)
//    Guessing a single exact ID risks silently missing the real one (exactly
//    the failure mode under investigation). manbok's own AppIdentityCatalog.swift
//    already special-cases all three for DISPLAY NAME purposes — but that
//    catalog has no bearing on device SELECTION, which operates directly on
//    whatever literal bundleID CoreAudio reports. Pass "com.google.Chrome" as
//    the tracked argument and this spike's prefix match catches all three.
//    Unlike Firefox (one long-lived process), Chrome can have several matching
//    PIDs alive at once (multiple tabs/renderers, GPU, utility), so tracking
//    state is now keyed per-PID rather than a single scalar.
//
// 4. BT UID-PREFIX EPOCH / CHURN TRACKING — repeated captures showed the same
//    physical BT device under a different pair of AudioObjectIDs almost every
//    run, meaning the physical link was reconnecting repeatedly. Every ADD of
//    a bluetooth-role-paired UID gets an epoch number; epochs closer together
//    than 60s raise a CHURN warning, so a capture window's trustworthiness
//    (one continuous connection vs. straddling a reconnect) is visible at a
//    glance.
//
// 5. EMBEDDED manbok OS_LOG TAIL — shells out to `/usr/bin/log stream` for
//    subsystem=ai.manbok.app and interleaves those lines (prefixed [manbok])
//    directly into this same output, on the same clock, instead of hand-
//    correlating two separate log files after the fact.
//
// 6. SIBLING ANALYSIS — for each tracked process, states whether a same-UID-
//    prefix sibling with hasInput=true exists SOMEWHERE on the system but is
//    absent from that process's own raw device list (supports "stream never
//    moved to the new device") vs. present in the raw list but dropped by
//    hasInputStreams (would support a genuine attribution bug — never observed
//    so far, across Firefox or Chrome).
//
// Run: cd spikes && swift run pdv-debug-spike [seconds] [trackedPrefixes]
//   defaults: seconds=300, trackedPrefixes=org.mozilla.firefox
//   trackedPrefixes is a comma-separated list of bundle-ID PREFIXES, e.g.:
//     swift run pdv-debug-spike 180 com.google.Chrome
//     swift run pdv-debug-spike 180 org.mozilla.firefox,com.google.Chrome

// MARK: - Helpers

private func ts() -> String {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss.SSS"
    return df.string(from: Date())
}

private func emit(_ msg: String) {
    print("[\(ts())] \(msg)")
    fflush(stdout)
}

private func readUInt32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var val: UInt32 = 0
    var sz = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &sz, &val) == noErr ? val : nil
}

private func readPID(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> pid_t? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var val: pid_t = 0
    var sz = UInt32(MemoryLayout<pid_t>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &sz, &val) == noErr ? val : nil
}

private func readCFString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var ref: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &sz, &ref) == noErr,
          let cf = ref?.takeRetainedValue() else { return nil }
    return cf as String
}

private func readObjectIDs(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &sz) == noErr, sz > 0 else { return [] }
    let count = Int(sz) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &sz, &ids) == noErr else { return [] }
    return ids
}

// MARK: - Device info

private func deviceName(_ id: AudioDeviceID) -> String {
    readCFString(id, kAudioObjectPropertyName) ?? "?"
}

private func deviceUID(_ id: AudioDeviceID) -> String {
    readCFString(id, kAudioDevicePropertyDeviceUID) ?? "?"
}

private func hasInputStreams(_ id: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                          mScope: kAudioObjectPropertyScopeInput,
                                          mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &sz) == noErr else { return false }
    return sz > 0
}

private func isRunningSomewhere(_ id: AudioDeviceID) -> Bool {
    (readUInt32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
}

private func transportType(_ id: AudioDeviceID) -> String {
    guard let raw = readUInt32(id, kAudioDevicePropertyTransportType) else { return "?" }
    switch raw {
    case kAudioDeviceTransportTypeBuiltIn: return "builtin"
    case kAudioDeviceTransportTypeBluetooth: return "bt"
    case kAudioDeviceTransportTypeBluetoothLE: return "btle"
    case kAudioDeviceTransportTypeUSB: return "usb"
    case kAudioDeviceTransportTypeAggregate: return "aggregate"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    default: return "0x\(String(raw, radix: 16))"
    }
}

private func subDevices(_ id: AudioDeviceID) -> [AudioDeviceID] {
    readObjectIDs(id, kAudioAggregateDevicePropertyActiveSubDeviceList)
}

/// For BT-role-split UIDs like "80-99-E7-C1-B6-43:input" / "...:output", returns the
/// shared prefix ("80-99-E7-C1-B6-43"). Returns nil for UIDs that don't follow this
/// convention (e.g. BuiltInMicrophoneDevice).
private func btUIDPrefix(_ uid: String) -> String? {
    if uid.hasSuffix(":input") { return String(uid.dropLast(":input".count)) }
    if uid.hasSuffix(":output") { return String(uid.dropLast(":output".count)) }
    return nil
}

private func defaultInputDevice() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var id = AudioDeviceID(0)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &id) == noErr,
          id != kAudioObjectUnknown else { return nil }
    return id
}

private func allInputDeviceIDs() -> [AudioDeviceID] {
    let all = readObjectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    return all.filter { hasInputStreams($0) }
}

private func allDeviceIDs() -> [AudioDeviceID] {
    readObjectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
}

// MARK: - Tracked prefix family

/// Matches a bundleID against any of the tracked prefixes. Case-sensitive exact-prefix
/// match (mirrors CoreAudio's literal bundleID string — manbok's own AppIdentityCatalog
/// lowercases for DISPLAY matching, but device selection never does, so this spike
/// deliberately doesn't either, to see exactly what CoreAudio reports).
private func matchesTracked(_ bundleID: String, prefixes: [String]) -> Bool {
    prefixes.contains { bundleID.hasPrefix($0) }
}

// MARK: - VIEW A: Process → Mic (current manbok approach)

struct ProcSnap: Equatable {
    let pid: pid_t
    let bundleID: String
    let isRunningInput: Bool
    let rawDeviceIDs: [AudioDeviceID]
    let filteredDeviceIDs: [AudioDeviceID]
}

private func viewA_snapshotProcesses(ownPID: pid_t) -> [ProcSnap] {
    let procObjs = readObjectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    var result: [ProcSnap] = []
    for obj in procObjs {
        guard let pid = readPID(obj, kAudioProcessPropertyPID), pid != ownPID else { continue }
        let isRI = (readUInt32(obj, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
        guard isRI else { continue }
        let bundleID = readCFString(obj, kAudioProcessPropertyBundleID) ?? "pid:\(pid)"
        let rawDevs = readObjectIDs(obj, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
        let filtered = rawDevs.filter { hasInputStreams($0) }
        result.append(ProcSnap(pid: pid, bundleID: bundleID, isRunningInput: true,
                               rawDeviceIDs: rawDevs, filteredDeviceIDs: filtered))
    }
    return result
}

/// UNFILTERED scan (ignores IsRunningInput) for every process whose bundleID matches any
/// tracked prefix, keyed by PID. Used to print explicit true/false transitions per-process
/// rather than silently dropping a process the instant IsRunningInput goes false — and to
/// handle apps (Chrome) that can have several matching processes alive simultaneously,
/// unlike Firefox's single long-lived process.
private func rawTrackedFamilyStates(ownPID: pid_t, prefixes: [String]) -> [pid_t: (bundleID: String, isRunningInput: Bool)] {
    let procObjs = readObjectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    var result: [pid_t: (bundleID: String, isRunningInput: Bool)] = [:]
    for obj in procObjs {
        guard let pid = readPID(obj, kAudioProcessPropertyPID), pid != ownPID else { continue }
        let bundleID = readCFString(obj, kAudioProcessPropertyBundleID) ?? ""
        guard matchesTracked(bundleID, prefixes: prefixes) else { continue }
        let isRI = (readUInt32(obj, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
        result[pid] = (bundleID, isRI)
    }
    return result
}

/// Faithful-ish proxy for CaptureDevicePolicy.target(demand:), restricted to the tracked
/// family: unions filteredDeviceIDs across every currently-present tracked-matching
/// process, groups by device -> set of distinct holder bundleIDs (manbok's real scoring
/// key), picks the device held by the most distinct bundleIDs, ties broken by lowest
/// device ID (the spike has no real per-app "arrivedAt", so the arrival tiebreak from the
/// real policy is not reproduced — noted, not a gap in manbok itself).
private func simulateManbokResolve(procs: [ProcSnap], prefixes: [String]) -> (device: AudioDeviceID, holders: Set<String>)? {
    let matched = procs.filter { matchesTracked($0.bundleID, prefixes: prefixes) }
    var holderBundleIDs: [AudioDeviceID: Set<String>] = [:]
    for p in matched {
        for d in Set(p.filteredDeviceIDs) {
            holderBundleIDs[d, default: []].insert(p.bundleID)
        }
    }
    guard !holderBundleIDs.isEmpty else { return nil }
    let maxScore = holderBundleIDs.values.map(\.count).max()!
    let winner = holderBundleIDs.filter { $0.value.count == maxScore }.keys.min()!
    return (winner, holderBundleIDs[winner]!)
}

/// Sibling analysis: for every device NOT in a process's raw list, is there a same-UID-
/// prefix device (any role) that IS in its raw list? Distinguishes "the input sibling
/// simply isn't in this process's device list at all" (supports "stream bound at open
/// time, never moved") from "it's in the raw list but dropped by hasInputStreams" (would
/// support a genuine attribution bug — never observed so far).
private func siblingAnalysis(rawDeviceIDs: [AudioDeviceID], allKnownDeviceIDs: [AudioDeviceID]) -> [String] {
    var lines: [String] = []
    let rawPrefixes = Set(rawDeviceIDs.compactMap { btUIDPrefix(deviceUID($0)) })
    let rawSet = Set(rawDeviceIDs)
    for id in allKnownDeviceIDs where !rawSet.contains(id) {
        let uid = deviceUID(id)
        guard let prefix = btUIDPrefix(uid), rawPrefixes.contains(prefix), hasInputStreams(id) else { continue }
        lines.append("SIBLING NOT IN RAW LIST: \(deviceName(id))[\(id) uid=\(uid)] shares UID-prefix \(prefix) " +
                     "with a device this process DOES list, has input streams, but never appears in this process's own pdv# at all")
    }
    return lines
}

private func viewA_print(procs: [ProcSnap], allKnownDeviceIDs: [AudioDeviceID], trackedPrefixes: [String]) {
    emit("[VIEW A: process → mic]")
    if procs.isEmpty {
        emit("  (no processes with IsRunningInput)")
        return
    }
    for p in procs.sorted(by: { $0.pid < $1.pid }) {
        let rawDescs = p.rawDeviceIDs.map { id -> String in
            "\(deviceName(id))[id=\(id) uid=\(deviceUID(id)) transport=\(transportType(id)) hasInput=\(hasInputStreams(id))]"
        }
        let droppedCount = p.rawDeviceIDs.count - p.filteredDeviceIDs.count
        var line = "  pid=\(p.pid) bundle=\(p.bundleID)"
        line += "\n    raw-devices: \(rawDescs.isEmpty ? "(none)" : rawDescs.joined(separator: ", "))"
        if droppedCount > 0 {
            let dropped = Set(p.rawDeviceIDs).subtracting(p.filteredDeviceIDs)
            let droppedDescs = dropped.map { "\(deviceName($0))[\($0) uid=\(deviceUID($0))]" }
            line += "\n    !! DROPPED by hasInputStreams: \(droppedDescs.joined(separator: ", "))"
        }
        line += "\n    manbok-sees: \(p.filteredDeviceIDs.map { "\(deviceName($0))[\($0)]" }.joined(separator: ", "))"
        emit(line)
        if matchesTracked(p.bundleID, prefixes: trackedPrefixes) {
            for sibLine in siblingAnalysis(rawDeviceIDs: p.rawDeviceIDs, allKnownDeviceIDs: allKnownDeviceIDs) {
                emit("    !! \(sibLine)")
            }
        }
    }
    if let (device, holders) = simulateManbokResolve(procs: procs, prefixes: trackedPrefixes) {
        let holderList = holders.sorted().joined(separator: ", ")
        emit("  ★ A says MANBOK RECORDS: \(deviceName(device)) [\(device) uid=\(deviceUID(device))] (held by: \(holderList))")
    } else {
        emit("  ★ A says MANBOK RECORDS: (nil — no devices for tracked prefixes \(trackedPrefixes.joined(separator: ",")))")
    }
}

// MARK: - VIEW B: Mic → Process (reverse: who's using each device?)

struct DeviceUsageSnap: Equatable {
    let deviceID: AudioDeviceID
    let name: String
    let uid: String
    let transport: String
    let runningSomewhere: Bool
    let holders: [(pid: pid_t, bundleID: String)]

    static func == (lhs: DeviceUsageSnap, rhs: DeviceUsageSnap) -> Bool {
        lhs.deviceID == rhs.deviceID && lhs.runningSomewhere == rhs.runningSomewhere
            && lhs.holders.count == rhs.holders.count
            && zip(lhs.holders, rhs.holders).allSatisfy { $0.pid == $1.pid && $0.bundleID == $1.bundleID }
    }
}

private func viewB_snapshotDevices(ownPID: pid_t) -> [DeviceUsageSnap] {
    let inputDevs = allInputDeviceIDs()
    let procObjs = readObjectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)

    // Build a map: for each process, what input devices does it hold? (no IsRunningInput filter — we want ALL)
    struct ProcDevices {
        let pid: pid_t
        let bundleID: String
        let inputDeviceIDs: [AudioDeviceID]
    }
    var allProcDevices: [ProcDevices] = []
    for obj in procObjs {
        guard let pid = readPID(obj, kAudioProcessPropertyPID), pid != ownPID else { continue }
        let bundleID = readCFString(obj, kAudioProcessPropertyBundleID) ?? "pid:\(pid)"
        // Read ALL devices (global scope) so we don't miss anything
        let globalDevs = readObjectIDs(obj, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        let inputDevs = readObjectIDs(obj, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
        let combined = Array(Set(globalDevs + inputDevs))
        allProcDevices.append(ProcDevices(pid: pid, bundleID: bundleID, inputDeviceIDs: combined))
    }

    var result: [DeviceUsageSnap] = []
    for devID in inputDevs {
        let running = isRunningSomewhere(devID)
        // Find all processes that list this device
        var holders: [(pid: pid_t, bundleID: String)] = []
        for pd in allProcDevices {
            if pd.inputDeviceIDs.contains(devID) {
                holders.append((pid: pd.pid, bundleID: pd.bundleID))
            }
        }
        result.append(DeviceUsageSnap(
            deviceID: devID, name: deviceName(devID), uid: deviceUID(devID),
            transport: transportType(devID), runningSomewhere: running, holders: holders))
    }

    // Also check ALL devices (not just input) for IsRunningSomewhere — catches aggregates, output-only devices with hidden input
    let allDevs = allDeviceIDs()
    let inputSet = Set(inputDevs)
    for devID in allDevs where !inputSet.contains(devID) {
        let running = isRunningSomewhere(devID)
        if !running { continue }
        // This device is running but has no input streams — could be an aggregate or output device
        var holders: [(pid: pid_t, bundleID: String)] = []
        for pd in allProcDevices {
            if pd.inputDeviceIDs.contains(devID) {
                holders.append((pid: pd.pid, bundleID: pd.bundleID))
            }
        }
        result.append(DeviceUsageSnap(
            deviceID: devID, name: deviceName(devID), uid: deviceUID(devID),
            transport: transportType(devID), runningSomewhere: running, holders: holders))
    }

    return result
}

private func viewB_print(devices: [DeviceUsageSnap]) {
    emit("[VIEW B: mic → process]")
    let active = devices.filter { $0.runningSomewhere || !$0.holders.isEmpty }
    if active.isEmpty {
        emit("  (no devices active)")
        return
    }
    for d in devices.sorted(by: { $0.deviceID < $1.deviceID }) {
        let running = d.runningSomewhere
        let holderDescs = d.holders.map { "pid=\($0.pid) (\($0.bundleID))" }

        if !running && d.holders.isEmpty { continue }

        var line = "  \(d.name) [id=\(d.deviceID) uid=\(d.uid) transport=\(d.transport)]"
        line += " runningSomewhere=\(running)"
        if d.holders.isEmpty {
            if running {
                line += "\n    !! GHOST: device is running but NO process claims it"
            }
        } else {
            line += "\n    holders: \(holderDescs.joined(separator: ", "))"
        }
        emit(line)
    }
}

// MARK: - Cross-check: compare views

private func crossCheck(viewA: [ProcSnap], viewB: [DeviceUsageSnap]) {
    // Find devices that VIEW B says are running but VIEW A doesn't see
    let viewA_allDevices = Set(viewA.flatMap(\.rawDeviceIDs))
    for d in viewB where d.runningSomewhere {
        if !viewA_allDevices.contains(d.deviceID) && !d.holders.isEmpty {
            let holderDescs = d.holders.map { "\($0.bundleID)(pid=\($0.pid))" }
            emit("[CROSS-CHECK] ⚠ \(d.name)[\(d.deviceID)] has holders [\(holderDescs.joined(separator: ", "))] but NONE have IsRunningInput=true — invisible to VIEW A / manbok")
        }
    }

    // Find ghost devices (running somewhere, no holder found)
    for d in viewB where d.runningSomewhere && d.holders.isEmpty {
        emit("[CROSS-CHECK] ⚠ GHOST: \(d.name)[\(d.deviceID) uid=\(d.uid)] is runningSomewhere=true but no process holds it")
    }

    // Find processes in VIEW A whose devices aren't marked runningSomewhere
    let runningDevIDs = Set(viewB.filter(\.runningSomewhere).map(\.deviceID))
    for p in viewA {
        for devID in p.filteredDeviceIDs {
            if !runningDevIDs.contains(devID) {
                emit("[CROSS-CHECK] ⚠ pid=\(p.pid) (\(p.bundleID)) claims device \(deviceName(devID))[\(devID)] but device says runningSomewhere=false")
            }
        }
    }
}

// MARK: - BT epoch / churn tracking

private var btEpochByPrefix: [String: Int] = [:]
private var btEpochAddedAt: [String: [Date]] = [:]  // history of ADD timestamps per prefix, for churn detection

/// Call on every device ADD. Assigns/bumps an epoch number for BT-role-split UIDs and
/// prints a CHURN warning if the same physical device has reconnected within 60s.
private func noteBTDeviceAdded(uid: String, name: String, now: Date) {
    guard let prefix = btUIDPrefix(uid) else { return }
    let epoch = (btEpochByPrefix[prefix] ?? 0) + 1
    btEpochByPrefix[prefix] = epoch
    var history = btEpochAddedAt[prefix] ?? []
    history.append(now)
    btEpochAddedAt[prefix] = history
    emit("   epoch: \(name) [\(prefix)] is now on connection epoch #\(epoch)")
    if history.count >= 2 {
        let gap = now.timeIntervalSince(history[history.count - 2])
        if gap < 60 {
            emit("   !! CHURN WARNING: \(name) [\(prefix)] reconnected \(String(format: "%.1f", gap))s after its previous connection — treat any single capture window spanning this gap as UNRELIABLE (may straddle two connection epochs)")
        }
    }
}

private func btEpoch(for uid: String) -> Int? {
    guard let prefix = btUIDPrefix(uid) else { return nil }
    return btEpochByPrefix[prefix]
}

// MARK: - manbok os_log tail (merges manbok's own log into this same timeline)

private var manbokLogProcess: Process?

private func startManbokLogTail() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = [
        "stream",
        "--predicate", "subsystem == \"ai.manbok.app\"",
        "--style", "compact",
        "--level", "debug",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") where !line.isEmpty {
            // Skip the header/filter lines `log stream` prints on startup.
            if line.hasPrefix("Filtering the log") || line.hasPrefix("Timestamp") { continue }
            emit("[manbok] \(line)")
        }
    }

    do {
        try process.run()
        manbokLogProcess = process
        emit("(embedded) tailing manbok os_log — subsystem=ai.manbok.app, prefixed [manbok] below")
    } catch {
        emit("!! failed to start embedded `log stream` for manbok: \(error) — run it manually in a second terminal:")
        emit("   /usr/bin/log stream --predicate 'subsystem == \"ai.manbok.app\"' --level debug")
    }
}

private func stopManbokLogTail() {
    guard let process = manbokLogProcess else { return }
    process.terminate()
    manbokLogProcess = nil
}

// MARK: - Main

let ownPID = getpid()
let duration = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 300 : 300
let trackedPrefixes: [String] = {
    guard CommandLine.arguments.count > 2 else { return ["org.mozilla.firefox"] }
    return CommandLine.arguments[2].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
}()
let sampleInterval = 0.2  // was 1.0 — decisive prior event happened within a ~1.4s window

emit("=== pdv-debug-spike v4 === pid=\(ownPID) duration=\(duration)s tracked=\(trackedPrefixes.joined(separator: ",")) sample=\(sampleInterval)s")
emit("Views A (process→mic) and B (mic→process), plus: raw IsRunningInput transitions per")
emit("tracked PID, BT epoch/churn tracking, sibling analysis, embedded manbok log tail.")
print("")

signal(SIGINT) { _ in
    stopManbokLogTail()
    exit(0)
}

startManbokLogTail()

var lastProcsA: [ProcSnap] = []
var lastDevsB: [DeviceUsageSnap] = []
var lastInputDeviceIDs: Set<AudioDeviceID> = []
var lastDefaultInput: AudioDeviceID? = nil
var lastTrackedStates: [pid_t: (bundleID: String, isRunningInput: Bool)] = [:]
let startTime = Date()

func fullSnapshotAndPrint(elapsedLabel: String, defInput: AudioDeviceID?, inputDevs: [AudioDeviceID]) {
    print("--- \(elapsedLabel) ---")
    let defDesc = defInput.map { id -> String in
        let epoch = btEpoch(for: deviceUID(id)).map { " epoch#\($0)" } ?? ""
        return "\(deviceName(id)) [id=\(id) uid=\(deviceUID(id))\(epoch)]"
    } ?? "none"
    emit("default-input: \(defDesc)")
    emit("input-devices: \(inputDevs.map { "\(deviceName($0))[\($0)]" }.joined(separator: ", "))")
    print("")
    let procsA = viewA_snapshotProcesses(ownPID: ownPID)
    let devsB = viewB_snapshotDevices(ownPID: ownPID)
    let allKnown = allDeviceIDs()
    viewA_print(procs: procsA, allKnownDeviceIDs: allKnown, trackedPrefixes: trackedPrefixes)
    print("")
    viewB_print(devices: devsB)
    print("")
    crossCheck(viewA: procsA, viewB: devsB)
    print("")
    lastProcsA = procsA
    lastDevsB = devsB
}

func tick() {
    let now = Date()
    let defInput = defaultInputDevice()
    let inputDevs = allInputDeviceIDs()
    let inputSet = Set(inputDevs)

    // --- raw tracked-family IsRunningInput transitions, per PID (independent of View A's filter) ---
    let trackedStates = rawTrackedFamilyStates(ownPID: ownPID, prefixes: trackedPrefixes)
    let allPIDs = Set(trackedStates.keys).union(lastTrackedStates.keys)
    for pid in allPIDs.sorted() {
        let old = lastTrackedStates[pid]
        let new = trackedStates[pid]
        switch (old, new) {
        case (nil, .some(let n)):
            emit("!! TRACKED(\(n.bundleID)) pid=\(pid) process object appeared, IsRunningInput=\(n.isRunningInput)")
        case (.some(let o), nil):
            emit("!! TRACKED(\(o.bundleID)) pid=\(pid) process object DISAPPEARED (was IsRunningInput=\(o.isRunningInput))")
        case (.some(let o), .some(let n)) where o.isRunningInput != n.isRunningInput || o.bundleID != n.bundleID:
            emit("!! TRACKED(\(n.bundleID)) pid=\(pid) IsRunningInput: \(o.isRunningInput) → \(n.isRunningInput)")
        default:
            break
        }
    }
    lastTrackedStates = trackedStates

    // --- default input / device list change detection (unchanged logic, denser sampling) ---
    var sawTransition = false
    if defInput != lastDefaultInput {
        let oldDesc = lastDefaultInput.map { "\(deviceName($0))[\($0)]" } ?? "none"
        let newDesc = defInput.map { "\(deviceName($0))[\($0)]" } ?? "none"
        emit("!! DEFAULT INPUT CHANGED: \(oldDesc) → \(newDesc)")
        lastDefaultInput = defInput
        sawTransition = true
    }

    let added = inputSet.subtracting(lastInputDeviceIDs)
    let removed = lastInputDeviceIDs.subtracting(inputSet)
    if !added.isEmpty || !removed.isEmpty {
        emit("!! DEVICE LIST CHANGED")
        for id in added {
            let uid = deviceUID(id)
            emit("   + ADDED: \(deviceName(id)) [id=\(id) uid=\(uid) transport=\(transportType(id))]")
            noteBTDeviceAdded(uid: uid, name: deviceName(id), now: now)
        }
        for id in removed { emit("   - REMOVED: id=\(id)") }
        sawTransition = true
    }

    let procsA = viewA_snapshotProcesses(ownPID: ownPID)
    let devsB = viewB_snapshotDevices(ownPID: ownPID)
    let changed = procsA != lastProcsA || devsB != lastDevsB || sawTransition
    if changed {
        let elapsed = Int(now.timeIntervalSince(startTime))
        fullSnapshotAndPrint(elapsedLabel: "t=\(elapsed)s", defInput: defInput, inputDevs: inputDevs)
    }

    lastInputDeviceIDs = inputSet
}

emit("== INITIAL STATE ==")
lastDefaultInput = defaultInputDevice()
let initInputDevs = allInputDeviceIDs()
lastInputDeviceIDs = Set(initInputDevs)
lastTrackedStates = rawTrackedFamilyStates(ownPID: ownPID, prefixes: trackedPrefixes)
for id in initInputDevs {
    let uid = deviceUID(id)
    if btUIDPrefix(uid) != nil { noteBTDeviceAdded(uid: uid, name: deviceName(id), now: startTime) }
}
fullSnapshotAndPrint(elapsedLabel: "t=0s (initial)", defInput: lastDefaultInput, inputDevs: initInputDevs)

for id in initInputDevs where transportType(id) == "aggregate" {
    let subs = subDevices(id)
    let subDescs = subs.map { "\(deviceName($0))[\($0)]" }
    emit("aggregate-detail: \(deviceName(id))[\(id)] subs=\(subDescs)")
}
print("")

let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
timer.schedule(deadline: .now() + sampleInterval, repeating: sampleInterval)
timer.setEventHandler {
    let elapsed = Date().timeIntervalSince(startTime)
    if elapsed >= Double(duration) {
        emit("=== done (\(duration)s) ===")
        stopManbokLogTail()
        exit(0)
    }
    tick()
}
timer.resume()

RunLoop.main.run()
