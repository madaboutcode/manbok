import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import ManbokCore

// MARK: - CONTRACT (AUHALWorker)
//
// GUARANTEES
// - Implements PinnedAudioCapturing using a raw CoreAudio HAL output unit
//   (kAudioUnitSubType_HALOutput) pinned via kAudioOutputUnitProperty_CurrentDevice —
//   no AVAudioEngine involved (validated: spikes/Sources/PinnedCaptureSpike).
// - Converts backend-native buffers (device-native rate/channels, Float32) to canonical
//   PCM (s16le 16kHz mono) via AVAudioConverter.
// - peak is the max absolute sample value in the chunk; peak == 0 iff every sample is
//   exactly zero.
// - sink is called on the render callback's own real-time thread.
// - Resolves .device(id) exactly; resolves .systemDefault to the current default input
//   AT START — bound concretely from then on (boundDevice).
// - Reads the device's nominal sample rate fresh at every start — never cached
//   (BT-HFP devices renegotiate rate on reconnect).
// - Rebuilds the buffer lists on any delivered stream-format change (e.g. channel-count
//   flips) — at most the in-flight buffer is lost. Conversion is delegated to
//   CanonicalPCMConverter, which guarantees stream continuity and self-detects format
//   changes (rebuilds its own converter when the input format it sees changes).
// - Render targets rotate across 3 buffer lists: memory the converter may still reference
//   from one conversion is not rewritten for another 3 render cycles, making the
//   aliasing-safety in CanonicalPCMConverter's contract structural rather than dependent
//   on converter drain behavior.
// - stop() is an idempotent barrier: an internal stop flag is checked before any sink
//   call; no sink call happens once stop() returns.
// - boundDevice is non-nil after a successful start and constant until stop().
//
// EXPECTS
// - Exactly one start() per instance — a second call is a programmer error
//   (preconditionFailure). A restart means a NEW instance.
// - start()/stop() called from one caller thread (the supervisor's apply context).
//
// FAILURE BEHAVIOR
// - start throws PinnedCaptureError (.permissionDenied, .deviceUnavailable,
//   .backendFailure) — the unit is torn down on any setup failure, never left
//   half-initialized.
// - Mid-run device death shows up as silence of callbacks, not an error — detecting
//   that is the supervisor's watchdog job, not this worker's.
// - AudioUnitRender / converter errors: logged .warning, frame dropped, capture keeps
//   running.
//
// DOES NOT
// - Retry, observe devices for restart decisions, own policy, buffer beyond one chunk,
//   or touch the registry.

/// Raw AUHAL (CoreAudio HAL output unit) implementation of PinnedAudioCapturing.
public final class AUHALWorker: PinnedAudioCapturing {
    private let log = AppLog(category: .capture)
    private let maxFrames: UInt32 = 4096

    private let chunkConverter = CanonicalPCMConverter()

    // Owned only by the render/format-change threads once started; guarded by formatLock
    // since the format-change listener can fire concurrently with the render callback.
    private let formatLock = NSLock()
    private var audioUnit: AudioUnit?
    private var streamFormat = AudioStreamBasicDescription()

    // Rotating render targets: memory rendered into slot N is not reused until slot N is
    // selected again renderSlotCount renders later, so anything the converter may still
    // reference from a prior render (beyond the documented per-call drain) reads stable
    // memory rather than data the very next render callback overwrote.
    private let renderSlotCount = 3
    private var bufferLists: [UnsafeMutableAudioBufferListPointer] = []
    private var renderSlot = 0

    private var sink: ((CaptureChunk) -> Void)?

    // Disposable-instance + stop-barrier bookkeeping.
    private let stateLock = NSLock()
    private var started = false
    private var stopped = false

    public private(set) var boundDevice: AudioDeviceID?

    public init() {}

    deinit {
        stop()
    }

    public func start(target: CaptureTarget, sink: @escaping (CaptureChunk) -> Void) throws {
        stateLock.lock()
        if started {
            stateLock.unlock()
            preconditionFailure("AUHALWorker.start called twice — disposable worker, create a new instance")
        }
        started = true
        stateLock.unlock()

        guard MicrophoneAuthorization.ensureAuthorized() else {
            throw PinnedCaptureError.permissionDenied
        }

        let deviceID: AudioDeviceID
        switch target {
        case .systemDefault:
            guard let id = InputDeviceObserver.defaultInputDeviceID() else {
                throw PinnedCaptureError.backendFailure("no default input device available")
            }
            deviceID = id
        case .device(let id):
            guard Self.deviceExists(id) else {
                throw PinnedCaptureError.deviceUnavailable(id)
            }
            guard Self.deviceHasInputStreams(id) else {
                throw PinnedCaptureError.deviceUnavailable(id)
            }
            deviceID = id
        }

        self.sink = sink

        do {
            try setupAUHAL(deviceID: deviceID)
        } catch {
            self.sink = nil
            throw error
        }

        boundDevice = deviceID
        log.notice("AUHAL started — device=\(InputDeviceObserver.deviceName(deviceID)) (\(deviceID))")
    }

    public func stop() {
        stateLock.lock()
        guard started, !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        stateLock.unlock()

        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil
        sink = nil

        formatLock.lock()
        for slot in bufferLists {
            for buffer in slot { buffer.mData?.deallocate() }
            free(slot.unsafeMutablePointer)
        }
        bufferLists = []
        formatLock.unlock()

        log.notice("AUHAL stopped")
    }

    // MARK: - Setup

    private func setupAUHAL(deviceID: AudioDeviceID) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw PinnedCaptureError.backendFailure("AudioComponentFindNext found no HAL output component")
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            throw PinnedCaptureError.backendFailure("AudioComponentInstanceNew failed: \(fourCC(status))")
        }

        var one: UInt32 = 1
        status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw PinnedCaptureError.backendFailure("EnableIO(input) failed: \(fourCC(status))")
        }

        var zero: UInt32 = 0
        status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw PinnedCaptureError.backendFailure("EnableIO(output) failed: \(fourCC(status))")
        }

        // Pin the device AFTER enabling IO, BEFORE format/initialize.
        var mutableDeviceID = deviceID
        status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw PinnedCaptureError.backendFailure("CurrentDevice failed: \(fourCC(status))")
        }

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, &formatSize)
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw PinnedCaptureError.backendFailure("GetStreamFormat failed: \(fourCC(status))")
        }

        // Resolved fresh on every start — never cached (BT-HFP renegotiates on reconnect).
        // AUHAL's default client format does NOT auto-adopt the pinned device's nominal
        // rate; a mismatch here produces kAudioUnitErr_CannotDoInCurrentContext on render.
        if let nominalRate = Self.nominalSampleRate(deviceID), format.mSampleRate != nominalRate {
            format.mSampleRate = nominalRate
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, formatSize)
            guard status == noErr else {
                AudioComponentInstanceDispose(unit)
                throw PinnedCaptureError.backendFailure("SetStreamFormat(\(Int(nominalRate))Hz) failed: \(fourCC(status))")
            }
        }

        var maxFramesVar = maxFrames
        status = AudioUnitSetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &maxFramesVar, UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw PinnedCaptureError.backendFailure("MaximumFramesPerSlice failed: \(fourCC(status))")
        }

        formatLock.lock()
        streamFormat = format
        do {
            try rebuildBuffers(for: format)
        } catch {
            formatLock.unlock()
            AudioComponentInstanceDispose(unit)
            throw error
        }
        formatLock.unlock()

        var callbackStruct = AURenderCallbackStruct(
            inputProc: auhalWorkerRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw PinnedCaptureError.backendFailure("SetInputCallback failed: \(fourCC(status))")
        }

        // Best-effort: catches delivered-format changes (e.g. channel-count flips) so the
        // converter/buffers get rebuilt proactively. Render-time detection is the backstop.
        let listenerStatus = AudioUnitAddPropertyListener(
            unit, kAudioUnitProperty_StreamFormat, auhalWorkerFormatChangeListener, Unmanaged.passUnretained(self).toOpaque()
        )
        if listenerStatus != noErr {
            log.warning("failed to register stream-format change listener: OSStatus \(listenerStatus)")
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw PinnedCaptureError.backendFailure("AudioUnitInitialize failed: \(fourCC(status))")
        }

        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw PinnedCaptureError.backendFailure("AudioOutputUnitStart failed: \(fourCC(status))")
        }

        self.audioUnit = unit
    }

    /// Allocates renderSlotCount fresh, identical buffer lists sized for `format`. Caller
    /// holds formatLock.
    private func rebuildBuffers(for format: AudioStreamBasicDescription) throws {
        for oldSlot in bufferLists {
            for buffer in oldSlot { buffer.mData?.deallocate() }
            free(oldSlot.unsafeMutablePointer)
        }
        bufferLists = []
        renderSlot = 0

        for _ in 0..<renderSlotCount {
            bufferLists.append(try allocateBufferList(for: format))
        }
    }

    /// Allocates one buffer list sized for `format`.
    private func allocateBufferList(for format: AudioStreamBasicDescription) throws -> UnsafeMutableAudioBufferListPointer {
        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let numBuffers = isNonInterleaved ? max(Int(format.mChannelsPerFrame), 1) : 1
        let bytesPerBuffer = isNonInterleaved
            ? Int(maxFrames) * Int(format.mBitsPerChannel / 8)
            : Int(maxFrames) * Int(format.mBytesPerFrame)
        guard bytesPerBuffer > 0 else {
            throw PinnedCaptureError.backendFailure("invalid stream format: 0 bytes per buffer")
        }

        let abl = AudioBufferList.allocate(maximumBuffers: numBuffers)
        for i in 0..<numBuffers {
            let dataPtr = UnsafeMutableRawPointer.allocate(byteCount: bytesPerBuffer, alignment: 16)
            abl[i] = AudioBuffer(
                mNumberChannels: isNonInterleaved ? 1 : format.mChannelsPerFrame,
                mDataByteSize: UInt32(bytesPerBuffer),
                mData: dataPtr
            )
        }
        return abl
    }

    // MARK: - Format-change notification (off the render thread)

    fileprivate func handleFormatChangeNotification() {
        guard let unit = audioUnit else { return }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, &size)
        guard status == noErr else {
            log.warning("format-change notification: failed to read new stream format (OSStatus \(status))")
            return
        }

        formatLock.lock()
        defer { formatLock.unlock() }
        do {
            try rebuildBuffers(for: format)
            streamFormat = format
            log.notice(
                "AUHAL stream format changed — buffers rebuilt: \(Int(format.mSampleRate))Hz ch=\(format.mChannelsPerFrame)"
            )
        } catch {
            log.warning("format-change notification: failed to rebuild buffers — \(error)")
        }
    }

    // MARK: - Render (real-time IO thread)

    fileprivate func handleRender(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        numberFrames: UInt32
    ) -> OSStatus {
        stateLock.lock()
        let isStopped = stopped
        stateLock.unlock()
        guard !isStopped else { return noErr }

        formatLock.lock()

        guard let unit = audioUnit, !bufferLists.isEmpty else {
            formatLock.unlock()
            return noErr
        }

        let slot = bufferLists[renderSlot]
        renderSlot = (renderSlot + 1) % renderSlotCount

        let format = streamFormat
        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerChannelFrame: UInt32 = isNonInterleaved
            ? UInt32(format.mBitsPerChannel / 8)
            : format.mBytesPerFrame
        for i in 0..<slot.count {
            slot[i].mDataByteSize = numberFrames * bytesPerChannelFrame
        }

        let renderStatus = AudioUnitRender(unit, ioActionFlags, timeStamp, busNumber, numberFrames, slot.unsafeMutablePointer)
        guard renderStatus == noErr else {
            formatLock.unlock()
            log.warning("AudioUnitRender failed: \(fourCC(renderStatus))")
            return renderStatus
        }

        var mutableFormat = format
        guard let inputFormat = AVAudioFormat(streamDescription: &mutableFormat) else {
            formatLock.unlock()
            log.warning("dropped frame: could not build AVAudioFormat from stream description")
            return noErr
        }

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            bufferListNoCopy: slot.unsafeMutablePointer,
            deallocator: nil
        ) else {
            formatLock.unlock()
            log.warning("dropped frame: could not wrap render buffer as AVAudioPCMBuffer")
            return noErr
        }
        pcmBuffer.frameLength = numberFrames

        let chunk = chunkConverter.convert(pcmBuffer)
        formatLock.unlock()

        guard let chunk else { return noErr }

        stateLock.lock()
        let stillStopped = stopped
        stateLock.unlock()
        guard !stillStopped else { return noErr }

        sink?(chunk)
        return noErr
    }

    // MARK: - Device helpers

    private static func deviceExists(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return false
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return false }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return false
        }
        return ids.contains(id)
    }

    private static func deviceHasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func nominalSampleRate(_ id: AudioDeviceID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}

/// Renders an OSStatus as its four-char-code form when printable, else the raw decimal value.
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

/// C trampoline for kAudioOutputUnitProperty_SetInputCallback. Must be context-free (no
/// captures) to be usable as an AURenderCallback function pointer; state comes back through
/// inRefCon, set to an unretained pointer to the owning AUHALWorker.
private func auhalWorkerRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let worker = Unmanaged<AUHALWorker>.fromOpaque(inRefCon).takeUnretainedValue()
    return worker.handleRender(ioActionFlags: ioActionFlags, timeStamp: inTimeStamp, busNumber: inBusNumber, numberFrames: inNumberFrames)
}

/// C trampoline for the kAudioUnitProperty_StreamFormat change listener.
private func auhalWorkerFormatChangeListener(
    inRefCon: UnsafeMutableRawPointer,
    inUnit: AudioUnit,
    inID: AudioUnitPropertyID,
    inScope: AudioUnitScope,
    inElement: AudioUnitElement
) {
    guard inID == kAudioUnitProperty_StreamFormat,
          inScope == kAudioUnitScope_Output,
          inElement == 1 else { return }
    let worker = Unmanaged<AUHALWorker>.fromOpaque(inRefCon).takeUnretainedValue()
    worker.handleFormatChangeNotification()
}
