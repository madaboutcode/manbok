import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation

// Spike: which backend can HOLD a pinned, non-default input device on macOS.
//
// Incident this spike investigates: spikes/Sources/DeviceSwitchSpike/main.swift proved that
// AVAudioEngine cannot capture from a pinned non-default input device — setting
// kAudioOutputUnitProperty_CurrentDevice on its inputNode's AudioUnit works for ~1 callback,
// then the engine silently reconfigures back to the system default and stops (a permanent
// ~1s flap loop). We need a backend that survives this. This spike puts two candidates
// side by side, selected by --backend:
//
//   auhal:     a raw CoreAudio HAL output unit (kAudioUnitSubType_HALOutput), pinned directly
//              to an AudioDeviceID via kAudioOutputUnitProperty_CurrentDevice — no AVAudioEngine
//              involved at all.
//   avcapture: AVCaptureSession + AVCaptureDeviceInput + AVCaptureAudioDataOutput, pinned to the
//              AVCaptureDevice matching the same CoreAudio device.
//
// Run (both REQUIRE --backend and --device):
//   cd spikes && swift run pinned-capture-spike [seconds] --backend auhal --device <substring>
//   cd spikes && swift run pinned-capture-spike [seconds] --backend avcapture --device <substring>
//
// NO auto-restart — unlike DeviceSwitchSpike, we are testing whether the backend holds the
// device WITHOUT intervention. If capture dies, we want to see it stay dead.
//
// Manual scenarios (run once per invocation, per backend):
//   P1: stable callbacks for full duration while default input is a DIFFERENT device
//   P2: capture unaffected when the default input changes mid-run
//   P3: when the PINNED device disappears mid-run, spike prints clear device-gone events
//       (capture stopping then is expected and fine)

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

// MARK: - HAL helpers (copied from DeviceSwitchSpike; scope is a parameter because
// kAudioProcessPropertyDevices ('pdv#') requires Input/Output scope to select which device
// list comes back — see AudioHardware.h doc comment)

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

// MARK: - Device helpers (copied from DeviceSwitchSpike, plus deviceUID for AUHAL<->AVCapture matching)

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

private func deviceUID(_ id: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &unmanaged) == noErr,
          let cf = unmanaged?.takeRetainedValue() else { return nil }
    return cf as String
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

/// Ground-truth "is this device actually doing IO" signal, read directly off the CoreAudio
/// device object rather than trusting our own start/stop bookkeeping. This is the same class
/// of signal manbok's ProcessAudioMonitor uses — useful here because the whole point of the
/// spike is to catch a backend that silently stops delivering audio while still claiming to
/// be "running".
private func deviceIsRunning(_ id: AudioDeviceID) -> Bool {
    (readUInt32(id, kAudioDevicePropertyDeviceIsRunning) ?? 0) != 0
}

// MARK: - RMS

private func dbfs(fromRMS rms: Float) -> Float {
    guard rms > 0 else { return -120 }
    let db = 20 * log10(rms)
    return max(db, -120)
}

// MARK: - Stats accumulator (shared by both backends)

/// Accumulates per-second stats fed by either backend's callback. Callbacks land on a real-time
/// or dedicated dispatch-queue thread; the summary printer runs on the main RunLoop. NSLock
/// matches the pattern DeviceSwitchSpike's TapStats already uses for the same tap-vs-main-thread
/// handoff — acceptable for a spike, not something to carry into production real-time code.
private final class TapStats {
    private let lock = NSLock()
    private var callbackCount = 0
    private var frameCount: UInt64 = 0
    private var sumSquares: Double = 0
    private var sampleCount: Int = 0
    private(set) var lastCallbackAt: Date?
    private var lastRenderErrorStatus: OSStatus?
    private var renderErrorChanged = false

    func record(frames: Int, sumSquares deltaSumSquares: Double, sampleCount deltaSampleCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        callbackCount += 1
        frameCount += UInt64(frames)
        sumSquares += deltaSumSquares
        sampleCount += deltaSampleCount
        lastCallbackAt = Date()
    }

    /// Records an OSStatus surfaced from inside a real-time callback (e.g. AudioUnitRender
    /// failing). Only flags a change when the status differs from the last one seen, so the
    /// once-per-second drain doesn't get called on every single failing callback.
    func recordRenderError(_ status: OSStatus) {
        lock.lock()
        defer { lock.unlock() }
        if lastRenderErrorStatus != status {
            lastRenderErrorStatus = status
            renderErrorChanged = true
        }
    }

    func drainRenderErrorChange() -> (changed: Bool, status: OSStatus?) {
        lock.lock()
        defer {
            renderErrorChanged = false
            lock.unlock()
        }
        return (renderErrorChanged, lastRenderErrorStatus)
    }

    func drainSecond() -> (callbacks: Int, frames: UInt64, rmsDbfs: Float) {
        lock.lock()
        defer {
            callbackCount = 0
            sumSquares = 0
            sampleCount = 0
            lock.unlock()
        }
        let rms: Float = sampleCount > 0 ? Float(sqrt(sumSquares / Double(sampleCount))) : 0
        return (callbackCount, frameCount, dbfs(fromRMS: rms))
    }

    func timeSinceLastCallback() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastCallbackAt else { return nil }
        return Date().timeIntervalSince(last)
    }
}

// MARK: - Shared PCM extraction (used by the avcapture backend to turn a CMSampleBuffer into
// frame/RMS stats without pulling in AVAudioPCMBuffer format-description gymnastics)

private struct PCMExtraction {
    let frameCount: Int
    let sumSquares: Double
    let sampleCount: Int
    let asbd: AudioStreamBasicDescription
}

private var loggedUnsupportedPCMFormat = false

/// Reads the CMSampleBuffer's native ASBD and walks its AudioBufferList computing sum-of-squares
/// for RMS. Handles the two formats real input hardware realistically hands back (Float32 and
/// signed Int16); anything else is counted toward frames/callbacks but contributes 0 to RMS,
/// logged once so it isn't silently misleading.
private func extractPCM(from sampleBuffer: CMSampleBuffer) -> PCMExtraction? {
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
        return nil
    }
    let asbd = asbdPtr.pointee

    let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
    guard numFrames > 0 else {
        return PCMExtraction(frameCount: 0, sumSquares: 0, sampleCount: 0, asbd: asbd)
    }

    let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    let numBuffers = isNonInterleaved ? Int(asbd.mChannelsPerFrame) : 1

    let abl = AudioBufferList.allocate(maximumBuffers: max(numBuffers, 1))
    defer { free(abl.unsafeMutablePointer) }
    var blockBuffer: CMBlockBuffer?

    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: nil,
        bufferListOut: abl.unsafeMutablePointer,
        bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: max(numBuffers, 1)),
        blockBufferAllocator: nil,
        blockBufferMemoryAllocator: nil,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        blockBufferOut: &blockBuffer
    )
    guard status == noErr else {
        emit("!! avcapture: CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer failed: \(fourCC(status))")
        return nil
    }

    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let bitsPerChannel = Int(asbd.mBitsPerChannel)
    var sumSquares = 0.0
    var sampleCount = 0

    for buffer in abl {
        guard let data = buffer.mData else { continue }
        let byteCount = Int(buffer.mDataByteSize)
        if isFloat, bitsPerChannel == 32 {
            let count = byteCount / MemoryLayout<Float32>.size
            let ptr = data.bindMemory(to: Float32.self, capacity: count)
            for i in 0..<count {
                let s = Double(ptr[i])
                sumSquares += s * s
            }
            sampleCount += count
        } else if !isFloat, bitsPerChannel == 16 {
            let count = byteCount / MemoryLayout<Int16>.size
            let ptr = data.bindMemory(to: Int16.self, capacity: count)
            for i in 0..<count {
                let s = Double(ptr[i]) / 32768.0
                sumSquares += s * s
            }
            sampleCount += count
        } else if !loggedUnsupportedPCMFormat {
            loggedUnsupportedPCMFormat = true
            emit("!! avcapture: PCM format float=\(isFloat) bits=\(bitsPerChannel) not handled by RMS calc — frames still counted, rms will read 0 for these buffers")
        }
    }

    return PCMExtraction(frameCount: numFrames, sumSquares: sumSquares, sampleCount: sampleCount, asbd: asbd)
}

// MARK: - Capture backend protocol

private protocol CaptureBackend: AnyObject {
    var isRunning: Bool { get }
    func stop()
}

// MARK: - Backend 1: auhal (raw CoreAudio HAL output unit, pinned via kAudioOutputUnitProperty_CurrentDevice)

private enum AUHALError: Error, CustomStringConvertible {
    case componentNotFound
    case osStatus(String, OSStatus)

    var description: String {
        switch self {
        case .componentNotFound: return "AudioComponentFindNext found no kAudioUnitSubType_HALOutput component"
        case .osStatus(let call, let status): return "\(call) failed: \(fourCC(status))"
        }
    }
}

private final class AUHALCapture: CaptureBackend {
    private(set) var audioUnit: AudioUnit?
    private(set) var streamFormat = AudioStreamBasicDescription()
    private var bufferList: UnsafeMutableAudioBufferListPointer?
    private let stats: TapStats
    let deviceID: AudioDeviceID
    private let maxFrames: UInt32 = 4096

    var isRunning: Bool { deviceIsRunning(deviceID) }

    init(deviceID: AudioDeviceID, stats: TapStats) {
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
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AUHALError.componentNotFound
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else { throw AUHALError.osStatus("AudioComponentInstanceNew", status) }
        audioUnit = unit

        // Enable input on element 1, disable output on element 0 — this AU defaults to being
        // an output unit, we want it purely for input capture.
        var one: UInt32 = 1
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw AUHALError.osStatus("EnableIO(input, element 1)", status) }

        var zero: UInt32 = 0
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw AUHALError.osStatus("EnableIO(output, element 0)", status) }

        // Pin the device AFTER enabling IO, BEFORE initialize — per spec.
        var mutableDeviceID = deviceID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw AUHALError.osStatus("CurrentDevice -> \(deviceLabel(deviceID))", status) }
        emit("auhal: pinned CurrentDevice to \(deviceLabel(deviceID))")

        // Read (not force-override) the client-side stream format: output scope of the input
        // element (1) is the format AudioUnitRender hands back to us. JUDGMENT CALL: we log
        // whatever the AU reports rather than setting our own AudioStreamBasicDescription —
        // HAL output units default to a sane client format, and extractPCM-equivalent handling
        // below copes with both Float32 and Int16 if a device ever reports something else.
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, &formatSize)
        guard status == noErr else { throw AUHALError.osStatus("GetStreamFormat(output, element 1)", status) }
        streamFormat = format
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        emit("auhal: client stream format = \(Int(format.mSampleRate))Hz \(format.mChannelsPerFrame)ch float=\(isFloat) bits=\(format.mBitsPerChannel) interleaved=\(!isNonInterleaved) (using AU default, not overriding)")

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

    /// Called from the C render callback trampoline. Pulls audio via AudioUnitRender into our
    /// pre-allocated buffer list, then feeds sum-of-squares into stats. Runs on CoreAudio's
    /// real-time IO thread.
    fileprivate func handleRender(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        numberFrames: UInt32
    ) -> OSStatus {
        guard let unit = audioUnit, let bufferList else { return -50 } // paramErr

        let isNonInterleaved = (streamFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerChannelFrame: UInt32 = isNonInterleaved
            ? UInt32(streamFormat.mBitsPerChannel / 8)
            : streamFormat.mBytesPerFrame
        for i in 0..<bufferList.count {
            bufferList[i].mDataByteSize = numberFrames * bytesPerChannelFrame
        }

        let status = AudioUnitRender(unit, ioActionFlags, timeStamp, busNumber, numberFrames, bufferList.unsafeMutablePointer)
        guard status == noErr else {
            stats.recordRenderError(status)
            return status
        }

        let isFloat = (streamFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = Int(streamFormat.mBitsPerChannel)
        var sumSquares = 0.0
        var sampleCount = 0
        for buffer in bufferList {
            guard let data = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            if isFloat, bitsPerChannel == 32 {
                let count = byteCount / MemoryLayout<Float32>.size
                let ptr = data.bindMemory(to: Float32.self, capacity: count)
                for i in 0..<count {
                    let s = Double(ptr[i])
                    sumSquares += s * s
                }
                sampleCount += count
            } else if !isFloat, bitsPerChannel == 16 {
                let count = byteCount / MemoryLayout<Int16>.size
                let ptr = data.bindMemory(to: Int16.self, capacity: count)
                for i in 0..<count {
                    let s = Double(ptr[i]) / 32768.0
                    sumSquares += s * s
                }
                sampleCount += count
            }
        }
        stats.record(frames: Int(numberFrames), sumSquares: sumSquares, sampleCount: sampleCount)
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

/// C trampoline for kAudioOutputUnitProperty_SetInputCallback. Must be a context-free function
/// (no captures) to be usable as an AURenderCallback function pointer; state comes back through
/// inRefCon, which we set to an unretained pointer to the owning AUHALCapture.
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

// MARK: - Backend 2: avcapture (AVCaptureSession pinned to an AVCaptureDevice)

private enum AVCaptureBackendError: Error, CustomStringConvertible {
    case noMatchingDevice(String)
    case cannotAddInput
    case cannotAddOutput

    var description: String {
        switch self {
        case .noMatchingDevice(let s): return "no AVCaptureDevice matches '\(s)' (checked CoreAudio-UID match and name-substring fallback)"
        case .cannotAddInput: return "AVCaptureSession.canAddInput returned false"
        case .cannotAddOutput: return "AVCaptureSession.canAddOutput returned false"
        }
    }
}

private final class AVCaptureBackend: NSObject, CaptureBackend, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let stats: TapStats
    private let queue = DispatchQueue(label: "ai.manbok.spike.pinnedcapture.avcapture")
    private var loggedFormat = false

    var isRunning: Bool { session.isRunning }

    init(stats: TapStats) {
        self.stats = stats
    }

    func start(device: AVCaptureDevice) throws {
        session.beginConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw AVCaptureBackendError.cannotAddInput }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw AVCaptureBackendError.cannotAddOutput }
        session.addOutput(output)

        session.commitConfiguration()
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let result = extractPCM(from: sampleBuffer) else { return }
        if !loggedFormat {
            loggedFormat = true
            let isFloat = (result.asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            let isNonInterleaved = (result.asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            emit("avcapture: native sample buffer format = \(Int(result.asbd.mSampleRate))Hz \(result.asbd.mChannelsPerFrame)ch float=\(isFloat) bits=\(result.asbd.mBitsPerChannel) interleaved=\(!isNonInterleaved)")
        }
        stats.record(frames: result.frameCount, sumSquares: result.sumSquares, sampleCount: result.sampleCount)
    }
}

/// Resolves the AVCaptureDevice that corresponds to a pinned CoreAudio AudioDeviceID.
/// JUDGMENT CALL: preferred path matches by CoreAudio device UID (AVCaptureDevice's uniqueID
/// for audio devices is the same CoreAudio UID string) so both backends are guaranteed to pin
/// the literal same physical device. Falls back to a case-insensitive name-substring match
/// (as the spec allows) if UID resolution fails for any reason.
private func resolveAVCaptureDevice(pinnedDeviceID: AudioDeviceID, substring: String) -> AVCaptureDevice? {
    if let uid = deviceUID(pinnedDeviceID), let device = AVCaptureDevice(uniqueID: uid) {
        emit("avcapture: resolved AVCaptureDevice via CoreAudio UID '\(uid)'")
        return device
    }
    emit("!! avcapture: could not resolve AVCaptureDevice via CoreAudio UID — falling back to name-substring match")
    let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
    return discovery.devices.first { $0.localizedName.lowercased().contains(substring.lowercased()) }
}

// MARK: - pdv# (process input-device mapping) probe (copied from DeviceSwitchSpike)

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

// MARK: - CLI args

private enum Backend: String {
    case auhal
    case avcapture
}

private struct Args {
    var duration: Double = 90
    var backend: Backend?
    var deviceSubstring: String?
}

private func usageAndExit() -> Never {
    emit("!! usage: pinned-capture-spike [seconds] --backend auhal|avcapture --device <name-substring>")
    exit(1)
}

private func parseArgs() -> Args {
    var args = Args()
    let rest = Array(CommandLine.arguments.dropFirst())
    var positionalConsumed = false
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--backend":
            guard i + 1 < rest.count, let backend = Backend(rawValue: rest[i + 1]) else {
                emit("!! --backend requires a value of 'auhal' or 'avcapture'")
                usageAndExit()
            }
            args.backend = backend
            i += 1
        case "--device":
            guard i + 1 < rest.count else {
                emit("!! --device requires a value")
                usageAndExit()
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
    guard args.backend != nil, args.deviceSubstring != nil else {
        emit("!! both --backend and --device are required")
        usageAndExit()
    }
    return args
}

// MARK: - Main

emit("=== pinned-capture-spike ===")
let ownPID = getpid()
private let args = parseArgs()
private let backendKind = args.backend!
private let deviceSubstring = args.deviceSubstring!
emit("pid=\(ownPID) duration=\(Int(args.duration))s backend=\(backendKind.rawValue) device=\(deviceSubstring)")
print("")
print("PASS CRITERIA:")
print("  P1: stable callbacks for full duration while default input is a DIFFERENT device")
print("  P2: capture unaffected when the default input changes mid-run")
print("  P3: when the PINNED device disappears mid-run, spike prints clear device-gone events")
print("      (capture stopping then is expected and fine)")
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

let matches = inputDeviceIDs().filter { deviceName($0).lowercased().contains(deviceSubstring.lowercased()) }
guard let pinnedDeviceID = matches.first else {
    emit("!! no input device name contains '\(deviceSubstring)' — available input devices:")
    for id in inputDeviceIDs() {
        emit("     \(deviceLabel(id))")
    }
    exit(1)
}
if matches.count > 1 {
    emit("!! WARNING: '\(deviceSubstring)' matched \(matches.count) input devices, using first: \(deviceLabel(pinnedDeviceID)) — matches were: \(matches.map { deviceLabel($0) })")
}
emit("resolved --device '\(deviceSubstring)' -> \(deviceLabel(pinnedDeviceID))")

private let stats = TapStats()
private var activeBackend: CaptureBackend!

do {
    switch backendKind {
    case .auhal:
        let capture = AUHALCapture(deviceID: pinnedDeviceID, stats: stats)
        try capture.start()
        activeBackend = capture
        emit("auhal: AudioOutputUnitStart succeeded")
    case .avcapture:
        guard let device = resolveAVCaptureDevice(pinnedDeviceID: pinnedDeviceID, substring: deviceSubstring) else {
            emit("!! \(AVCaptureBackendError.noMatchingDevice(deviceSubstring))")
            exit(1)
        }
        emit("avcapture: chosen AVCaptureDevice = \(device.localizedName) (uid=\(device.uniqueID))")
        let capture = AVCaptureBackend(stats: stats)
        try capture.start(device: device)
        activeBackend = capture
        emit("avcapture: session.startRunning() called")
    }
} catch {
    emit("!! backend start failed: \(error)")
    exit(1)
}

// MARK: AVCaptureSession / AVCaptureDevice notifications (avcapture backend only)

if backendKind == .avcapture, let avBackend = activeBackend as? AVCaptureBackend {
    NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: avBackend.session, queue: .main) { note in
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        emit("!! AVCaptureSession runtimeError: \(error?.localizedDescription ?? "unknown") \(error.map { "code=\($0.code)" } ?? "")")
    }
    NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: avBackend.session, queue: .main) { note in
        // JUDGMENT CALL: AVCaptureSessionInterruptionReasonKey / AVCaptureSession.InterruptionReason
        // are marked API_UNAVAILABLE(macos) in the SDK (they're iOS-only concepts — phone calls,
        // backgrounding, system pressure). On macOS the notification fires with no typed reason
        // available, so we just log that it fired plus whatever userInfo came along.
        emit("!! AVCaptureSession wasInterrupted: userInfo=\(note.userInfo ?? [:])")
    }
    NotificationCenter.default.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: avBackend.session, queue: .main) { _ in
        emit("!! AVCaptureSession interruptionEnded")
    }
}

NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { note in
    if let dev = note.object as? AVCaptureDevice {
        emit("!! AVCaptureDevice wasDisconnected: \(dev.localizedName) (\(dev.uniqueID))")
    }
}
NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { note in
    if let dev = note.object as? AVCaptureDevice {
        emit("!! AVCaptureDevice wasConnected: \(dev.localizedName) (\(dev.uniqueID))")
    }
}

// MARK: Device-list snapshot for observer (device-list-changed)

private func snapshotDeviceList() -> [AudioDeviceID: (name: String, hasInput: Bool)] {
    var snap: [AudioDeviceID: (String, Bool)] = [:]
    for id in allDeviceIDs() {
        snap[id] = (deviceName(id), deviceHasInputStreams(id))
    }
    return snap
}

private var lastDeviceSnapshot = snapshotDeviceList()
private var lastProcessDeviceMap = probeProcessInputDevices(ownPID: ownPID)

// MARK: Observer — default input device changed

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
}
AudioObjectAddPropertyListenerBlock(
    AudioObjectID(kAudioObjectSystemObject), &defaultInputListenerAddr, DispatchQueue.main, defaultInputListenerBlock
)

// MARK: Observer — device list changed (also flags when the PINNED device itself disappears — P3)

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
    if removedIDs.contains(pinnedDeviceID) {
        emit("!! PINNED DEVICE DISCONNECTED: \(deviceLabel(pinnedDeviceID)) — capture backend stopping/stalling from here is expected (P3)")
    }
    lastDeviceSnapshot = current
}
AudioObjectAddPropertyListenerBlock(
    AudioObjectID(kAudioObjectSystemObject), &deviceListAddr, DispatchQueue.main, deviceListListenerBlock
)

// MARK: Timer — 1s summary + 1s pdv# poll + render-error drain, driven from RunLoop.main

let startTime = Date()
var elapsedSeconds = 0

let summaryTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
summaryTimer.schedule(deadline: .now() + 1, repeating: 1)
summaryTimer.setEventHandler {
    elapsedSeconds += 1
    let (callbacks, frames, rms) = stats.drainSecond()
    let running = activeBackend?.isRunning ?? false
    let currentDefault = defaultInputID().map { deviceLabel($0) } ?? "unknown"
    emit("[t=\(elapsedSeconds)s] callbacks=\(callbacks) frames=\(frames) rms=\(String(format: "%.1f", rms))dBFS running=\(running) pinned=\(deviceLabel(pinnedDeviceID)) default=\(currentDefault)")

    let (changed, status) = stats.drainRenderErrorChange()
    if changed, let status {
        emit("!! auhal: AudioUnitRender status changed to \(fourCC(status))")
    }

    // pdv# probe, once per second.
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
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInputListenerAddr, DispatchQueue.main, defaultInputListenerBlock)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceListAddr, DispatchQueue.main, deviceListListenerBlock)
        activeBackend?.stop()
        exit(0)
    }
}
summaryTimer.resume()

RunLoop.main.run()
