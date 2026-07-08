import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// TestMicHarness: a controllable mic-capture process for exercising manbok's capture pipeline
// under test. Takes a required scenario name so parallel test runs don't collide; listens on
// /tmp/test-mic-harness-<scenario>.sock for single-line commands (DEVICES, START, STOP, SWITCH,
// STATUS, MUTE, UNMUTE, VOL, QUIT), pins an AUHAL input unit to a chosen device, and reports
// per-second audio stats to stderr plus a structured JSON event log at
// /tmp/test-mic-harness-<scenario>.log.
//
// Run: cd spikes && swift run test-mic-harness "test-mute-behavior"
// Talk to it: echo "DEVICES" | nc -U /tmp/test-mic-harness-test-mute-behavior.sock

// MARK: - stderr logging / timestamps

private func emit(_ msg: String) {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
}

private let hmsFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()
private func hms() -> String { hmsFormatter.string(from: Date()) }

private let iso8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private func isoNow() -> String { iso8601Formatter.string(from: Date()) }

private func jsonEscape(_ s: String) -> String {
    var out = ""
    for c in s {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        default: out.append(c)
        }
    }
    return out
}

/// Renders an OSStatus as its four-char-code form when printable, falling back to decimal.
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

// MARK: - HAL property helpers (pattern copied from PinnedCaptureSpike / DeviceTruthSpike)

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

private func readFloat64(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Float64? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
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

private func setFloat32(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement,
    _ value: Float32
) -> Bool {
    var v = value
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    let status = AudioObjectSetPropertyData(objectID, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    return status == noErr
}

private func readObjectIDs(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

// MARK: - Device helpers

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

private func allDeviceIDs() -> [AudioDeviceID] {
    readObjectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
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

/// Input-scope volume can live on the master element or per-channel; probe in that order.
private func inputVolumeElement(_ id: AudioDeviceID) -> AudioObjectPropertyElement? {
    for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
        if hasProperty(id, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: element) {
            return element
        }
    }
    return nil
}

private func getInputVolume(_ id: AudioDeviceID) -> Float32? {
    guard let element = inputVolumeElement(id) else { return nil }
    return readFloat32(id, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: element)
}

private func setInputVolume(_ id: AudioDeviceID, _ value: Float32) -> Bool {
    guard let element = inputVolumeElement(id) else { return false }
    return setFloat32(id, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: element, value)
}

private func resolveDevice(_ substring: String) -> (AudioDeviceID, String)? {
    let lower = substring.lowercased()
    for id in inputDeviceIDs() where deviceName(id).lowercased().contains(lower) {
        return (id, deviceName(id))
    }
    return nil
}

// MARK: - Capture stats (thread-safe; written from the AUHAL real-time render callback,
// read/drained from the main-thread timer and command handlers)

private final class CaptureStats {
    private let lock = NSLock()
    private var peakEver: Int16 = 0
    private var zeroRunCurrent = 0
    private var zeroRunMax = 0
    private var everSignaled = false

    private var windowSumSquares: Double = 0
    private var windowSampleCount = 0
    private var windowZeroCount = 0

    private var lastWindowRMS: Float = 0
    private var lastWindowZeroPercent: Float = 0

    func reset() {
        lock.lock(); defer { lock.unlock() }
        peakEver = 0
        zeroRunCurrent = 0
        zeroRunMax = 0
        everSignaled = false
        windowSumSquares = 0
        windowSampleCount = 0
        windowZeroCount = 0
        lastWindowRMS = 0
        lastWindowZeroPercent = 0
    }

    private func recordSample(_ isZero: Bool, absScaled: Int) {
        let clamped = Int16(clamping: absScaled)
        if clamped > peakEver { peakEver = clamped }
        if isZero {
            zeroRunCurrent += 1
            windowZeroCount += 1
        } else {
            everSignaled = true
            zeroRunCurrent = 0
        }
        if zeroRunCurrent > zeroRunMax { zeroRunMax = zeroRunCurrent }
        windowSampleCount += 1
    }

    func recordFloatSamples(_ ptr: UnsafePointer<Float32>, count: Int) {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<count {
            let s = ptr[i]
            recordSample(s == 0, absScaled: Int(Double(abs(s)) * 32767.0))
            windowSumSquares += Double(s) * Double(s)
        }
    }

    func recordInt16Samples(_ ptr: UnsafePointer<Int16>, count: Int) {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<count {
            let s = ptr[i]
            recordSample(s == 0, absScaled: abs(Int(s)))
            let f = Double(s) / 32768.0
            windowSumSquares += f * f
        }
    }

    /// Drains and resets the 1-second window (rms/zero-count), keeps session-wide peak/run/everSignaled.
    func drainWindow() -> (peak: Int16, rms: Float, zeroPercent: Float, zeroCount: Int, total: Int, zeroRunCurrent: Int, zeroRunMax: Int, everSignaled: Bool) {
        lock.lock(); defer { lock.unlock() }
        let rms: Float = windowSampleCount > 0 ? Float(sqrt(windowSumSquares / Double(windowSampleCount))) : 0
        let pct: Float = windowSampleCount > 0 ? Float(windowZeroCount) / Float(windowSampleCount) * 100 : 0
        let result = (peakEver, rms, pct, windowZeroCount, windowSampleCount, zeroRunCurrent, zeroRunMax, everSignaled)
        lastWindowRMS = rms
        lastWindowZeroPercent = pct
        windowSumSquares = 0
        windowSampleCount = 0
        windowZeroCount = 0
        return result
    }

    func snapshotForStatus() -> (peak: Int16, rms: Float, zeroPercent: Float, zeroRunMax: Int, everSignaled: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (peakEver, lastWindowRMS, lastWindowZeroPercent, zeroRunMax, everSignaled)
    }
}

// MARK: - AUHAL capture backend (pattern copied from PinnedCaptureSpike's AUHALCapture)

private enum AUHALError: Error, CustomStringConvertible {
    case componentNotFound
    case osStatus(String, OSStatus)

    var description: String {
        switch self {
        case .componentNotFound: return "no kAudioUnitSubType_HALOutput component found"
        case .osStatus(let call, let status): return "\(call) failed: \(fourCC(status))"
        }
    }
}

private final class AUHALCapture {
    private var audioUnit: AudioUnit?
    private var streamFormat = AudioStreamBasicDescription()
    private var bufferList: UnsafeMutableAudioBufferListPointer?
    private let stats: CaptureStats
    let deviceID: AudioDeviceID
    private let maxFrames: UInt32 = 4096

    init(deviceID: AudioDeviceID, stats: CaptureStats) {
        self.deviceID = deviceID
        self.stats = stats
    }

    func start() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else { throw AUHALError.componentNotFound }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else { throw AUHALError.osStatus("AudioComponentInstanceNew", status) }
        audioUnit = unit

        var one: UInt32 = 1
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw AUHALError.osStatus("EnableIO(input, element 1)", status) }

        var zero: UInt32 = 0
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw AUHALError.osStatus("EnableIO(output, element 0)", status) }

        var mutableDeviceID = deviceID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw AUHALError.osStatus("CurrentDevice -> \(deviceName(deviceID)) (\(deviceID))", status) }

        // Client stream format defaults to 44.1kHz float32; AUHAL will not sample-rate-convert on
        // input, so override to the device's nominal rate to avoid -10863 on every render call.
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, &formatSize)
        guard status == noErr else { throw AUHALError.osStatus("GetStreamFormat(output, element 1)", status) }

        if let nominalRate = readFloat64(deviceID, kAudioDevicePropertyNominalSampleRate), format.mSampleRate != nominalRate {
            format.mSampleRate = nominalRate
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, formatSize)
            guard status == noErr else { throw AUHALError.osStatus("SetStreamFormat(output, element 1, \(Int(nominalRate))Hz)", status) }
        }
        streamFormat = format
        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        emit("auhal: pinned \(deviceName(deviceID)) (\(deviceID)) — \(Int(format.mSampleRate))Hz \(format.mChannelsPerFrame)ch bits=\(format.mBitsPerChannel)")

        var maxFramesVar = maxFrames
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFramesVar, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw AUHALError.osStatus("MaximumFramesPerSlice", status) }

        let numBuffers = isNonInterleaved ? max(Int(format.mChannelsPerFrame), 1) : 1
        let bytesPerBuffer = isNonInterleaved
            ? Int(maxFrames) * Int(format.mBitsPerChannel / 8)
            : Int(maxFrames) * Int(format.mBytesPerFrame)

        let abl = AudioBufferList.allocate(maximumBuffers: numBuffers)
        for i in 0..<numBuffers {
            let dataPtr = UnsafeMutableRawPointer.allocate(byteCount: bytesPerBuffer, alignment: 16)
            abl[i] = AudioBuffer(
                mNumberChannels: isNonInterleaved ? 1 : format.mChannelsPerFrame,
                mDataByteSize: UInt32(bytesPerBuffer),
                mData: dataPtr
            )
        }
        bufferList = abl

        var callbackStruct = AURenderCallbackStruct(
            inputProc: auhalRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw AUHALError.osStatus("SetInputCallback", status) }

        status = AudioUnitInitialize(unit)
        guard status == noErr else { throw AUHALError.osStatus("AudioUnitInitialize", status) }

        status = AudioOutputUnitStart(unit)
        guard status == noErr else { throw AUHALError.osStatus("AudioOutputUnitStart", status) }
    }

    fileprivate func handleRender(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        numberFrames: UInt32
    ) -> OSStatus {
        guard let unit = audioUnit, let bufferList else { return -50 }

        var frames = numberFrames
        if frames > maxFrames {
            emit("!! auhal render: inNumberFrames=\(frames) exceeds allocated maxFrames=\(maxFrames), clamping")
            frames = maxFrames
        }

        let isNonInterleaved = (streamFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerChannelFrame: UInt32 = isNonInterleaved
            ? UInt32(streamFormat.mBitsPerChannel / 8)
            : streamFormat.mBytesPerFrame
        for i in 0..<bufferList.count {
            bufferList[i].mDataByteSize = frames * bytesPerChannelFrame
        }

        let status = AudioUnitRender(unit, ioActionFlags, timeStamp, busNumber, frames, bufferList.unsafeMutablePointer)
        guard status == noErr else { return status }

        let isFloat = (streamFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = Int(streamFormat.mBitsPerChannel)
        for buffer in bufferList {
            guard let data = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            if isFloat, bitsPerChannel == 32 {
                let count = byteCount / MemoryLayout<Float32>.size
                stats.recordFloatSamples(data.bindMemory(to: Float32.self, capacity: count), count: count)
            } else if !isFloat, bitsPerChannel == 16 {
                let count = byteCount / MemoryLayout<Int16>.size
                stats.recordInt16Samples(data.bindMemory(to: Int16.self, capacity: count), count: count)
            }
        }
        return noErr
    }

    func stop() {
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil
        if let bufferList {
            for buffer in bufferList {
                buffer.mData?.deallocate()
            }
            free(bufferList.unsafeMutablePointer)
        }
        bufferList = nil
    }
}

/// C trampoline for kAudioOutputUnitProperty_SetInputCallback — must be capture-free.
private func auhalRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<AUHALCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    return capture.handleRender(ioActionFlags: ioActionFlags, timeStamp: inTimeStamp, busNumber: inBusNumber, numberFrames: inNumberFrames)
}

// MARK: - Structured JSON event log

private final class EventLog {
    private let lock = NSLock()
    private let fileHandle: FileHandle

    init(path: String) {
        // Always (re)create the file so a new run of the same scenario name starts with a
        // clean log rather than appending to stale data from a previous run.
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: path) else {
            emit("!! cannot open log file at \(path)")
            exit(1)
        }
        fileHandle = fh
    }

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if let data = (line + "\n").data(using: .utf8) {
            fileHandle.write(data)
        }
    }
}

// MARK: - Harness state (all mutations happen on the main thread/queue)

private final class HarnessState {
    private(set) var capture: AUHALCapture?
    private(set) var currentDeviceID: AudioDeviceID?
    private(set) var currentDeviceName: String?
    private(set) var captureStartedAt: Date?
    var mutedDeviceID: AudioDeviceID?
    var mutedPreviousVolume: Float32?
    let stats = CaptureStats()

    var isCapturing: Bool { capture != nil }

    func startCapture(deviceID: AudioDeviceID, name: String) throws {
        stopCaptureIfRunning()
        stats.reset()
        let cap = AUHALCapture(deviceID: deviceID, stats: stats)
        try cap.start()
        capture = cap
        currentDeviceID = deviceID
        currentDeviceName = name
        captureStartedAt = Date()
    }

    func stopCaptureIfRunning() {
        guard let cap = capture else { return }
        cap.stop()
        capture = nil
        captureStartedAt = nil
    }
}

// MARK: - Command handling

private let scenarioName: String = {
    guard let name = CommandLine.arguments.dropFirst().first, !name.isEmpty else {
        emit("Usage: test-mic-harness <scenario-name>")
        emit("  e.g. test-mic-harness \"test-mute-behavior\"")
        exit(1)
    }
    return name
}()
private let socketPath = "/tmp/test-mic-harness-\(scenarioName).sock"
private let logPath = "/tmp/test-mic-harness-\(scenarioName).log"
private let eventLog = EventLog(path: logPath)
private let state = HarnessState()
private var didShutdown = false
private var shouldExitAfterResponse = false

private func cmdDevices() -> String {
    let ids = inputDeviceIDs()
    if ids.isEmpty { return "(no input devices found)" }
    return ids.map { id -> String in
        let transport = transportDescription(readUInt32(id, kAudioDevicePropertyTransportType) ?? 0)
        let name = deviceName(id)
        let running = (readUInt32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0 ? 1 : 0
        let vol = getInputVolume(id).map { String(format: "%.2f", $0) } ?? "n/a"
        let mute: String
        if hasProperty(id, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput) {
            mute = (readUInt32(id, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput) ?? 0) == 0 ? "0" : "1"
        } else {
            mute = "n/a"
        }
        return "\(id) \(transport) \(name) runningSomewhere=\(running) vol=\(vol) mute=\(mute)"
    }.joined(separator: "\n")
}

private func cmdStart(_ substring: String) -> String {
    guard !substring.isEmpty else { return "ERR START requires a device substring" }
    guard let (id, name) = resolveDevice(substring) else { return "ERR no input device matches '\(substring)'" }
    do {
        try state.startCapture(deviceID: id, name: name)
        eventLog.append(#"{"ts":"\#(isoNow())","scenario":"\#(jsonEscape(scenarioName))","event":"started","device":"\#(jsonEscape(name))","deviceId":\#(id)}"#)
        return "OK started on \(name) [\(id)]"
    } catch {
        return "ERR \(error)"
    }
}

private func cmdStop() -> String {
    if state.isCapturing {
        state.stopCaptureIfRunning()
        eventLog.append(#"{"ts":"\#(isoNow())","scenario":"\#(jsonEscape(scenarioName))","event":"stopped"}"#)
    }
    return "OK stopped"
}

private func cmdSwitch(_ substring: String) -> String {
    guard !substring.isEmpty else { return "ERR SWITCH requires a device substring" }
    guard let (id, name) = resolveDevice(substring) else { return "ERR no input device matches '\(substring)'" }
    if state.isCapturing {
        state.stopCaptureIfRunning()
        eventLog.append(#"{"ts":"\#(isoNow())","scenario":"\#(jsonEscape(scenarioName))","event":"stopped"}"#)
    }
    do {
        try state.startCapture(deviceID: id, name: name)
        eventLog.append(#"{"ts":"\#(isoNow())","scenario":"\#(jsonEscape(scenarioName))","event":"started","device":"\#(jsonEscape(name))","deviceId":\#(id)}"#)
        return "OK switched to \(name) [\(id)]"
    } catch {
        return "ERR \(error)"
    }
}

private func cmdStatus() -> String {
    let snap = state.stats.snapshotForStatus()
    let stateStr = state.isCapturing ? "capturing" : "idle"
    let deviceJSON = state.currentDeviceName.map { "\"\(jsonEscape($0))\"" } ?? "null"
    let deviceIdJSON = state.currentDeviceID.map { "\($0)" } ?? "null"
    let uptime = state.captureStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
    return #"{"state":"\#(stateStr)","device":\#(deviceJSON),"deviceId":\#(deviceIdJSON),"peak":\#(snap.peak),"rms":\#(String(format: "%.4f", snap.rms)),"zeroPercent":\#(String(format: "%.2f", snap.zeroPercent)),"zeroRunMax":\#(snap.zeroRunMax),"everSignaled":\#(snap.everSignaled),"uptimeSeconds":\#(uptime)}"#
}

private func cmdMute() -> String {
    guard let id = state.currentDeviceID, let name = state.currentDeviceName else {
        return "ERR no device selected — use START or SWITCH first"
    }
    guard state.mutedDeviceID == nil else { return "ERR already muted" }
    guard let prev = getInputVolume(id) else { return "ERR device does not expose an input volume scalar" }
    guard setInputVolume(id, 0.0) else { return "ERR failed to set volume to 0.0" }
    state.mutedDeviceID = id
    state.mutedPreviousVolume = prev
    eventLog.append(#"{"ts":"\#(isoNow())","scenario":"\#(jsonEscape(scenarioName))","event":"muted","device":"\#(jsonEscape(name))","prevVol":\#(String(format: "%.4f", prev))}"#)
    return "OK muted (vol 0.0, was \(String(format: "%.4f", prev)))"
}

private func cmdUnmute() -> String {
    guard let id = state.mutedDeviceID, let prev = state.mutedPreviousVolume else { return "ERR nothing to unmute" }
    guard setInputVolume(id, prev) else { return "ERR failed to restore volume" }
    let name = deviceName(id)
    state.mutedDeviceID = nil
    state.mutedPreviousVolume = nil
    eventLog.append(#"{"ts":"\#(isoNow())","scenario":"\#(jsonEscape(scenarioName))","event":"unmuted","device":"\#(jsonEscape(name))","restoredVol":\#(String(format: "%.4f", prev))}"#)
    return "OK unmuted (vol \(String(format: "%.4f", prev)))"
}

private func cmdVol(_ arg: String) -> String {
    guard let id = state.currentDeviceID else { return "ERR no device selected — use START or SWITCH first" }
    guard let value = Float32(arg), value >= 0.0, value <= 1.0 else {
        return "ERR VOL requires a value between 0.0 and 1.0"
    }
    guard setInputVolume(id, value) else { return "ERR failed to set volume" }
    return "OK vol=\(String(format: "%.4f", value))"
}

private func performShutdown() {
    guard !didShutdown else { return }
    didShutdown = true
    if state.isCapturing {
        state.stopCaptureIfRunning()
        eventLog.append(#"{"ts":"\#(isoNow())","scenario":"\#(jsonEscape(scenarioName))","event":"stopped"}"#)
    }
    if let id = state.mutedDeviceID, let prev = state.mutedPreviousVolume {
        _ = setInputVolume(id, prev)
        eventLog.append(#"{"ts":"\#(isoNow())","scenario":"\#(jsonEscape(scenarioName))","event":"unmuted","device":"\#(jsonEscape(deviceName(id)))","restoredVol":\#(String(format: "%.4f", prev))}"#)
        state.mutedDeviceID = nil
        state.mutedPreviousVolume = nil
    }
    unlink(socketPath)
    emit("[\(hms())] shutdown complete")
}

private func cmdQuit() -> String {
    performShutdown()
    shouldExitAfterResponse = true
    return "OK bye"
}

private func handleCommand(_ rawLine: String) -> String {
    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return "ERR empty command" }
    let firstSpace = line.firstIndex(of: " ")
    let cmd = firstSpace.map { String(line[line.startIndex..<$0]) } ?? line
    let rest = firstSpace.map { String(line[line.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
    switch cmd.uppercased() {
    case "DEVICES": return cmdDevices()
    case "START": return cmdStart(rest)
    case "STOP": return cmdStop()
    case "SWITCH": return cmdSwitch(rest)
    case "STATUS": return cmdStatus()
    case "MUTE": return cmdMute()
    case "UNMUTE": return cmdUnmute()
    case "VOL": return cmdVol(rest)
    case "QUIT": return cmdQuit()
    default: return "ERR unknown command '\(cmd)'"
    }
}

// MARK: - Unix socket server (one connection at a time, blocking accept loop on its own thread)

private func readLineFromSocket(_ fd: Int32) -> String {
    var data = [UInt8]()
    var byte: UInt8 = 0
    while true {
        let n = recv(fd, &byte, 1, 0)
        if n <= 0 { break }
        if byte == UInt8(ascii: "\n") { break }
        data.append(byte)
    }
    if data.last == UInt8(ascii: "\r") { data.removeLast() }
    return String(decoding: data, as: UTF8.self)
}

private func writeAll(_ fd: Int32, _ s: String) {
    let bytes = Array(s.utf8)
    var offset = 0
    while offset < bytes.count {
        let n = bytes[offset...].withUnsafeBufferPointer { ptr -> Int in
            send(fd, ptr.baseAddress, ptr.count, 0)
        }
        if n <= 0 { break }
        offset += n
    }
}

private func startServer(path: String) {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        emit("!! socket() failed: \(String(cString: strerror(errno)))")
        exit(1)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < 104 else {
        emit("!! socket path too long: \(path)")
        exit(1)
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
        let buf = rawPtr.bindMemory(to: Int8.self)
        for i in 0..<pathBytes.count { buf[i] = Int8(bitPattern: pathBytes[i]) }
        buf[pathBytes.count] = 0
    }

    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else {
        emit("!! bind() failed: \(String(cString: strerror(errno)))")
        exit(1)
    }
    guard listen(fd, 8) == 0 else {
        emit("!! listen() failed: \(String(cString: strerror(errno)))")
        exit(1)
    }

    Thread.detachNewThread {
        while true {
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                break
            }
            let line = readLineFromSocket(clientFD)
            let body = DispatchQueue.main.sync { handleCommand(line) }
            writeAll(clientFD, body + "\n\n")
            close(clientFD)
            let exitNow = DispatchQueue.main.sync { shouldExitAfterResponse }
            if exitNow { exit(0) }
        }
    }
}

// MARK: - Main

emit("[test-mic-harness] scenario=\(scenarioName) socket=\(socketPath) log=\(logPath)")
emit("pid=\(getpid())")

switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    break
case .notDetermined:
    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { _ in sem.signal() }
    sem.wait()
    if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
        emit("!! microphone permission denied — cannot produce valid measurements. Grant permission in System Settings → Privacy & Security → Microphone.")
        exit(1)
    }
default:
    emit("!! microphone not authorized — grant access in System Settings and re-run")
    exit(1)
}

signal(SIGPIPE, SIG_IGN)
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { performShutdown(); exit(0) }
sigintSource.resume()

let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { performShutdown(); exit(0) }
sigtermSource.resume()

let statsTimer = DispatchSource.makeTimerSource(queue: .main)
statsTimer.schedule(deadline: .now() + 1, repeating: 1)
statsTimer.setEventHandler {
    guard state.isCapturing else { return }
    let w = state.stats.drainWindow()
    emit("[\(hms())] peak=\(w.peak) rms=\(String(format: "%.4f", w.rms)) zeros=\(w.zeroCount)/\(w.total) (\(String(format: "%.1f", w.zeroPercent))%) zeroRun=\(w.zeroRunCurrent)/\(w.zeroRunMax) everSignaled=\(w.everSignaled)")
    eventLog.append(#"{"ts":"\#(isoNow())","scenario":"\#(jsonEscape(scenarioName))","event":"stats","peak":\#(w.peak),"rms":\#(String(format: "%.4f", w.rms)),"zeroPercent":\#(String(format: "%.2f", w.zeroPercent)),"zeroRunMax":\#(w.zeroRunMax),"everSignaled":\#(w.everSignaled)}"#)
}
statsTimer.resume()

startServer(path: socketPath)
emit("listening on \(socketPath)")

RunLoop.main.run()
