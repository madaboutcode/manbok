import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// Spike: does AUHAL ever deliver exact-zero-sample silence on a pinned device, and if so,
// for how long / under what conditions? This is the follow-up validation to PinnedCaptureSpike
// (which proved AUHAL can HOLD a pinned device) — here we instrument the actual sample stream
// for the silent-recording investigation: exact-zero run lengths, whether a signal is EVER
// seen at all, and how long AUHAL takes to start delivering signal after AudioUnitStart.
//
// Two modes, selected by the first argument (default: watch):
//
//   watch   — capture continuously, print a 1s stats line, accept single-key stdin markers
//             (no Enter needed) to annotate the log ("muted now", "switched app", ...), and
//             print a histogram summary on exit (timeout or Ctrl-C).
//     cd spikes && swift run silence-probe-spike watch --device <substring> [seconds]
//     cd spikes && swift run silence-probe-spike --device <substring> [seconds]   (watch is default)
//
//   cycles N — repeatedly start/stop the AUHAL unit N times, measuring start->first-callback
//              and first-callback->first-non-zero-sample latency per cycle, to validate
//              startup-grace-period assumptions used by any restart policy.
//     cd spikes && swift run silence-probe-spike cycles 10 --device <substring>
//
// AUHAL setup (pin device, negotiate sample rate, render callback) is the pattern already
// proved in PinnedCaptureSpike/main.swift, generalized here into one AUHALCapture class whose
// per-buffer callback both modes plug into — no AVAudioEngine involved.
//
// JUDGMENT CALL: manbok's capture target is mono. The per-sample zero-run/second accounting
// below walks raw PCM elements (not audio frames); for a mono device "sample" and "frame"
// coincide, so this is exact. A stereo/multi-channel pinned device would make the zero-run
// and per-second counts run ~channel-count times faster than wall-clock time — acceptable for
// a debugging spike, would need frame-level (all-channels-zero) checks to fix properly.

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

// MARK: - HAL helpers (copied from PinnedCaptureSpike)

private func readUInt32(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
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

private func readObjectIDs(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

// MARK: - Device helpers

private func deviceName(_ id: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &unmanaged) == noErr,
          let cf = unmanaged?.takeRetainedValue() else { return "device \(id)" }
    return cf as String
}

private func deviceLabel(_ id: AudioDeviceID) -> String { "\(deviceName(id)) (\(id))" }

private func allDeviceIDs() -> [AudioDeviceID] {
    readObjectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
}

private func deviceHasInputStreams(_ id: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
    return size > 0
}

private func inputDeviceIDs() -> [AudioDeviceID] { allDeviceIDs().filter { deviceHasInputStreams($0) } }

private func deviceIsRunning(_ id: AudioDeviceID) -> Bool {
    (readUInt32(id, kAudioDevicePropertyDeviceIsRunning) ?? 0) != 0
}

private func resolvePinnedDevice(substring: String?) -> AudioDeviceID {
    guard let substring else {
        emit("!! no --device given — available input devices:")
        for id in inputDeviceIDs() { emit("     \(deviceLabel(id))") }
        exit(1)
    }
    let matches = inputDeviceIDs().filter { deviceName($0).lowercased().contains(substring.lowercased()) }
    guard let pinnedDeviceID = matches.first else {
        emit("!! no input device name contains '\(substring)' — available input devices:")
        for id in inputDeviceIDs() { emit("     \(deviceLabel(id))") }
        exit(1)
    }
    if matches.count > 1 {
        emit("!! WARNING: '\(substring)' matched \(matches.count) input devices, using first: \(deviceLabel(pinnedDeviceID)) — matches were: \(matches.map { deviceLabel($0) })")
    }
    emit("resolved --device '\(substring)' -> \(deviceLabel(pinnedDeviceID))")
    return pinnedDeviceID
}

// MARK: - AUHAL capture (pattern copied from PinnedCaptureSpike, generalized so both `watch`
// and `cycles` modes share one start/stop/render implementation and just supply a different
// per-buffer callback)

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

private final class AUHALCapture {
    private(set) var audioUnit: AudioUnit?
    private(set) var streamFormat = AudioStreamBasicDescription()
    private var bufferList: UnsafeMutableAudioBufferListPointer?
    let deviceID: AudioDeviceID
    private let maxFrames: UInt32 = 4096
    private let onBuffer: (UnsafeMutableAudioBufferListPointer, AudioStreamBasicDescription) -> Void

    var isRunning: Bool { deviceIsRunning(deviceID) }

    init(deviceID: AudioDeviceID, onBuffer: @escaping (UnsafeMutableAudioBufferListPointer, AudioStreamBasicDescription) -> Void) {
        self.deviceID = deviceID
        self.onBuffer = onBuffer
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

        // Pin the device AFTER enabling IO, BEFORE initialize.
        var mutableDeviceID = deviceID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw AUHALError.osStatus("CurrentDevice -> \(deviceLabel(deviceID))", status) }

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, &formatSize)
        guard status == noErr else { throw AUHALError.osStatus("GetStreamFormat(output, element 1)", status) }

        // AUHAL's default client format is 44.1kHz float32 regardless of the pinned device's
        // nominal rate — a mismatch here produces -10863 on every AudioUnitRender call.
        if let nominalRate = readFloat64(deviceID, kAudioDevicePropertyNominalSampleRate), format.mSampleRate != nominalRate {
            format.mSampleRate = nominalRate
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, formatSize)
            guard status == noErr else { throw AUHALError.osStatus("SetStreamFormat(output, element 1, \(Int(nominalRate))Hz)", status) }
        }

        streamFormat = format
        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

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

    /// Called from the C render callback trampoline, on CoreAudio's real-time IO thread.
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
        guard status == noErr else { return status }

        onBuffer(bufferList, streamFormat)
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

/// C trampoline for kAudioOutputUnitProperty_SetInputCallback — must be context-free (no
/// captures); state comes back through inRefCon, an unretained pointer to the owning capture.
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

// MARK: - Per-sample walk (shared by watch + cycles callbacks)

private func forEachSample(
    _ bufferList: UnsafeMutableAudioBufferListPointer,
    _ format: AudioStreamBasicDescription,
    _ body: (Int16, Bool) -> Void
) {
    let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let bitsPerChannel = Int(format.mBitsPerChannel)
    for buffer in bufferList {
        guard let data = buffer.mData else { continue }
        let byteCount = Int(buffer.mDataByteSize)
        if isFloat, bitsPerChannel == 32 {
            let count = byteCount / MemoryLayout<Float32>.size
            let ptr = data.bindMemory(to: Float32.self, capacity: count)
            for i in 0..<count {
                let f = ptr[i]
                if f.isNaN || f.isInfinite {
                    body(0, true)
                    continue
                }
                let absInt16 = Int16(clamping: Int32((abs(f) * 32767).rounded()))
                body(absInt16, f == 0)
            }
        } else if !isFloat, bitsPerChannel == 16 {
            let count = byteCount / MemoryLayout<Int16>.size
            let ptr = data.bindMemory(to: Int16.self, capacity: count)
            for i in 0..<count {
                let s = ptr[i]
                body(Int16(abs(Int32(s))), s == 0)
            }
        }
    }
}

// MARK: - Non-blocking single-key stdin marker reader (watch mode)

private final class StdinMarkerReader {
    private var originalTermios = termios()
    private var rawModeEnabled = false
    private var thread: Thread?

    func start() {
        guard isatty(STDIN_FILENO) != 0 else {
            emit("stdin is not a TTY — markers disabled (need an interactive terminal)")
            return
        }
        tcgetattr(STDIN_FILENO, &originalTermios)
        var raw = originalTermios
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        withUnsafeMutableBytes(of: &raw.c_cc) { ccPtr in
            ccPtr[Int(VMIN)] = 1
            ccPtr[Int(VTIME)] = 0
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        rawModeEnabled = true

        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "stdin-marker-reader"
        thread = t
        t.start()
    }

    private func readLoop() {
        var byte: UInt8 = 0
        while true {
            let n = read(STDIN_FILENO, &byte, 1)
            guard n == 1 else {
                if n <= 0 { break } // EOF or closed fd
                continue
            }
            if byte == 0x0a || byte == 0x0d { continue } // ignore bare newline/CR
            let char = Character(UnicodeScalar(byte))
            let markTime = ts()
            DispatchQueue.main.async {
                emit("[MARK: \(char)] at \(markTime)")
            }
        }
    }

    func restore() {
        guard rawModeEnabled else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
        rawModeEnabled = false
    }
}

// MARK: - Watch mode stats

private final class SilenceStats {
    private let lock = NSLock()

    private var samplesThisSecond = 0
    private var zeroSamplesThisSecond = 0
    private var sumSquaresThisSecond: Double = 0
    private var peakThisSecond: Int16 = 0

    private var currentZeroRun: Int64 = 0
    private var maxZeroRunEverValue: Int64 = 0
    private var everSignaledFlag = false
    private var firstNonZeroAtValue: Date?

    private var totalSecondsCapturedValue = 0
    private var secondsAllZeroValue = 0
    private var secondsWithSignalValue = 0

    var captureStartedAt: Date?

    /// Per-buffer stats accumulated WITHOUT locking during sample iteration — the render
    /// callback fills one of these per invocation, then calls mergeBuffer() to take the lock
    /// exactly once per buffer rather than once per sample.
    struct BufferStats {
        let samples: Int
        let zeroSamples: Int
        let sumSquares: Double
        let peak: Int16
        let hasNonZero: Bool
        /// Zero-run length from the start of the buffer up to the first non-zero sample (or the
        /// whole buffer, if it never goes non-zero).
        let leadingZeroRun: Int64
        /// Zero-run length from the last non-zero sample to the end of the buffer (or the whole
        /// buffer, if it never goes non-zero).
        let trailingZeroRun: Int64
    }

    /// Merges one buffer's worth of stats into the shared accumulator — the only place that
    /// takes `lock`, once per render callback rather than once per sample.
    func mergeBuffer(_ b: BufferStats) {
        lock.lock()
        defer { lock.unlock() }
        samplesThisSecond += b.samples
        zeroSamplesThisSecond += b.zeroSamples
        sumSquaresThisSecond += b.sumSquares
        if b.peak > peakThisSecond { peakThisSecond = b.peak }

        if !b.hasNonZero {
            currentZeroRun += Int64(b.samples)
            if currentZeroRun > maxZeroRunEverValue { maxZeroRunEverValue = currentZeroRun }
        } else {
            currentZeroRun += b.leadingZeroRun
            if currentZeroRun > maxZeroRunEverValue { maxZeroRunEverValue = currentZeroRun }
            currentZeroRun = b.trailingZeroRun
            if !everSignaledFlag {
                everSignaledFlag = true
                firstNonZeroAtValue = Date()
            }
        }
    }

    struct SecondSnapshot {
        let samples: Int
        let zeroSamples: Int
        let rms: Float
        let peak: Int16
        let currentZeroRun: Int64
        let maxZeroRunEver: Int64
        let everSignaled: Bool
    }

    func drainSecond() -> SecondSnapshot {
        lock.lock()
        let samples = samplesThisSecond
        let zeroSamples = zeroSamplesThisSecond
        let rms: Float = samples > 0 ? Float(sqrt(sumSquaresThisSecond / Double(samples))) : 0
        let peak = peakThisSecond
        let run = currentZeroRun
        let maxRun = maxZeroRunEverValue
        let signaled = everSignaledFlag

        totalSecondsCapturedValue += 1
        if samples > 0 {
            if zeroSamples == samples { secondsAllZeroValue += 1 } else { secondsWithSignalValue += 1 }
        }
        samplesThisSecond = 0
        zeroSamplesThisSecond = 0
        sumSquaresThisSecond = 0
        peakThisSecond = 0
        lock.unlock()

        return SecondSnapshot(samples: samples, zeroSamples: zeroSamples, rms: rms, peak: peak, currentZeroRun: run, maxZeroRunEver: maxRun, everSignaled: signaled)
    }

    struct FinalSummary {
        let totalSeconds: Int
        let secondsAllZero: Int
        let secondsWithSignal: Int
        let maxZeroRunSamples: Int64
        let everSignaled: Bool
        let firstNonZeroAt: Date?
    }

    func finalSummary() -> FinalSummary {
        lock.lock()
        defer { lock.unlock() }
        return FinalSummary(
            totalSeconds: totalSecondsCapturedValue,
            secondsAllZero: secondsAllZeroValue,
            secondsWithSignal: secondsWithSignalValue,
            maxZeroRunSamples: maxZeroRunEverValue,
            everSignaled: everSignaledFlag,
            firstNonZeroAt: firstNonZeroAtValue
        )
    }
}

private func runWatchMode(pinnedDeviceID: AudioDeviceID, duration: Double) {
    emit("=== silence-probe-spike: watch mode ===")
    emit("device=\(deviceLabel(pinnedDeviceID)) duration=\(Int(duration))s")
    emit("type any key (no Enter needed) to drop a [MARK] in the log — e.g. mark 'muted now', 'switched app'")
    print("")

    let stats = SilenceStats()
    let capture = AUHALCapture(deviceID: pinnedDeviceID) { bufferList, format in
        var samples = 0
        var zeroSamples = 0
        var sumSquares = 0.0
        var peak: Int16 = 0
        var hasNonZero = false
        var sawNonZeroYet = false
        var runInBuffer: Int64 = 0
        var leadingZeroRun: Int64 = 0

        forEachSample(bufferList, format) { absInt16, isZero in
            samples += 1
            if absInt16 > peak { peak = absInt16 }
            let normalized = Double(absInt16) / 32768.0
            sumSquares += normalized * normalized

            if isZero {
                zeroSamples += 1
                runInBuffer += 1
                if !sawNonZeroYet { leadingZeroRun = runInBuffer }
            } else {
                hasNonZero = true
                sawNonZeroYet = true
                runInBuffer = 0
            }
        }
        let trailingZeroRun = runInBuffer
        if !hasNonZero { leadingZeroRun = Int64(samples) }

        stats.mergeBuffer(SilenceStats.BufferStats(
            samples: samples,
            zeroSamples: zeroSamples,
            sumSquares: sumSquares,
            peak: peak,
            hasNonZero: hasNonZero,
            leadingZeroRun: leadingZeroRun,
            trailingZeroRun: trailingZeroRun
        ))
    }

    do {
        try capture.start()
        stats.captureStartedAt = Date()
        let isFloat = (capture.streamFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        emit("auhal: AudioOutputUnitStart succeeded, format=\(Int(capture.streamFormat.mSampleRate))Hz \(capture.streamFormat.mChannelsPerFrame)ch float=\(isFloat) bits=\(capture.streamFormat.mBitsPerChannel)")
    } catch {
        emit("!! backend start failed: \(error)")
        exit(1)
    }

    let markerReader = StdinMarkerReader()
    markerReader.start()

    func printFinalSummaryAndExit(reason: String) -> Never {
        capture.stop()
        markerReader.restore()
        let summary = stats.finalSummary()
        let sampleRate = capture.streamFormat.mSampleRate
        let maxRunSeconds = sampleRate > 0 ? Double(summary.maxZeroRunSamples) / sampleRate : 0
        print("")
        emit("=== done (\(reason)) — summary ===")
        emit("total seconds captured:         \(summary.totalSeconds)")
        emit("seconds 100% zero samples:      \(summary.secondsAllZero)")
        emit("seconds with any non-zero:      \(summary.secondsWithSignal)")
        emit("max continuous zero-run:        \(summary.maxZeroRunSamples) samples (~\(String(format: "%.2f", maxRunSeconds))s)")
        emit("everSignaled:                   \(summary.everSignaled)")
        if let startedAt = stats.captureStartedAt, let firstNonZero = summary.firstNonZeroAt {
            let grace = firstNonZero.timeIntervalSince(startedAt)
            emit("startup grace (start->signal):  \(String(format: "%.3f", grace))s")
        } else {
            emit("startup grace (start->signal):  n/a — no non-zero sample ever seen")
        }
        exit(0)
    }

    signal(SIGINT, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler { printFinalSummaryAndExit(reason: "Ctrl-C") }
    sigintSource.resume()

    var elapsedSeconds = 0
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        elapsedSeconds += 1
        let snap = stats.drainSecond()
        emit("[t=\(elapsedSeconds)s] rms=\(String(format: "%.4f", snap.rms)) peak=\(snap.peak) zero=\(snap.zeroSamples)/\(snap.samples) zeroRun=\(snap.currentZeroRun) maxZeroRun=\(snap.maxZeroRunEver) everSignaled=\(snap.everSignaled)")
        if elapsedSeconds >= Int(duration) {
            printFinalSummaryAndExit(reason: "\(Int(duration))s timeout")
        }
    }
    timer.resume()

    RunLoop.main.run()
}

// MARK: - Cycles mode

private struct CycleResult {
    let index: Int
    let startToFirstCallback: TimeInterval?
    let callbackToFirstNonZero: TimeInterval?
    let timedOut: Bool
}

private final class CycleTimingStats {
    private let lock = NSLock()
    private var firstCallbackAtValue: Date?
    private var firstNonZeroAtValue: Date?

    func recordCallback(hasNonZero: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if firstCallbackAtValue == nil { firstCallbackAtValue = now }
        if hasNonZero, firstNonZeroAtValue == nil { firstNonZeroAtValue = now }
    }

    var firstCallbackAt: Date? {
        lock.lock(); defer { lock.unlock() }; return firstCallbackAtValue
    }
    var firstNonZeroAt: Date? {
        lock.lock(); defer { lock.unlock() }; return firstNonZeroAtValue
    }
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    if sorted.count == 1 { return sorted[0] }
    let rank = p * Double(sorted.count - 1)
    let lower = Int(rank.rounded(.down))
    let upper = Int(rank.rounded(.up))
    if lower == upper { return sorted[lower] }
    let frac = rank - Double(lower)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * frac
}

private func summarizeMs(_ label: String, _ valuesSeconds: [Double]) {
    guard !valuesSeconds.isEmpty else {
        emit("  \(label): n/a (no samples)")
        return
    }
    let ms = valuesSeconds.map { $0 * 1000 }
    let minV = ms.min()!
    let maxV = ms.max()!
    let mean = ms.reduce(0, +) / Double(ms.count)
    let p95 = percentile(ms, 0.95)
    emit("  \(label): min=\(String(format: "%.1f", minV))ms max=\(String(format: "%.1f", maxV))ms mean=\(String(format: "%.1f", mean))ms p95=\(String(format: "%.1f", p95))ms (n=\(ms.count))")
}

private let cycleSignalTimeout: TimeInterval = 5.0

private func runCyclesMode(pinnedDeviceID: AudioDeviceID, cycleCount: Int) {
    emit("=== silence-probe-spike: cycles mode ===")
    emit("device=\(deviceLabel(pinnedDeviceID)) cycles=\(cycleCount)")
    print("")

    var results: [CycleResult] = []

    for cycleIndex in 1...cycleCount {
        let timing = CycleTimingStats()
        let capture = AUHALCapture(deviceID: pinnedDeviceID) { bufferList, format in
            var hasNonZero = false
            forEachSample(bufferList, format) { _, isZero in
                if !isZero { hasNonZero = true }
            }
            timing.recordCallback(hasNonZero: hasNonZero)
        }

        let startAt = Date()
        do {
            try capture.start()
        } catch {
            emit("!! cycle \(cycleIndex)/\(cycleCount): start failed: \(error)")
            results.append(CycleResult(index: cycleIndex, startToFirstCallback: nil, callbackToFirstNonZero: nil, timedOut: true))
            continue
        }

        // Busy-poll for the first non-zero sample (or timeout) — the render callback fires on
        // CoreAudio's own real-time thread, independent of any RunLoop on this thread.
        let deadline = Date().addingTimeInterval(cycleSignalTimeout)
        while timing.firstNonZeroAt == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        capture.stop()

        let firstCallback = timing.firstCallbackAt
        let firstNonZero = timing.firstNonZeroAt
        let startToCallback = firstCallback.map { $0.timeIntervalSince(startAt) }
        let callbackToNonZero: TimeInterval? = {
            guard let firstCallback, let firstNonZero else { return nil }
            return firstNonZero.timeIntervalSince(firstCallback)
        }()

        let callbackStr = startToCallback.map { String(format: "%.1fms", $0 * 1000) } ?? "no callback"
        let nonZeroStr = callbackToNonZero.map { String(format: "%.1fms", $0 * 1000) } ?? (firstCallback == nil ? "n/a" : "timed out, no signal")
        emit("cycle \(cycleIndex)/\(cycleCount): start->callback=\(callbackStr) callback->signal=\(nonZeroStr)")

        results.append(CycleResult(index: cycleIndex, startToFirstCallback: startToCallback, callbackToFirstNonZero: callbackToNonZero, timedOut: firstNonZero == nil))

        // Brief pause between cycles so the previous unit fully tears down before the next
        // AudioComponentInstanceNew — mirrors spaced restarts rather than hammering the HAL.
        Thread.sleep(forTimeInterval: 0.3)
    }

    print("")
    emit("=== cycles summary (n=\(cycleCount)) ===")
    let timedOutCount = results.filter { $0.timedOut }.count
    if timedOutCount > 0 {
        emit("  \(timedOutCount)/\(cycleCount) cycles never saw a non-zero sample within \(Int(cycleSignalTimeout))s")
    }
    summarizeMs("start -> first IO callback", results.compactMap { $0.startToFirstCallback })
    summarizeMs("first callback -> first non-zero sample", results.compactMap { $0.callbackToFirstNonZero })
}

// MARK: - CLI args

private enum Mode {
    case watch(duration: Double)
    case cycles(count: Int)
}

private struct Args {
    var mode: Mode = .watch(duration: 30)
    var deviceSubstring: String?
}

private func usageAndExit() -> Never {
    emit("!! usage:")
    emit("!!   silence-probe-spike watch --device <substring> [seconds]")
    emit("!!   silence-probe-spike cycles <N> --device <substring>")
    exit(1)
}

private func parseArgs() -> Args {
    var rest = Array(CommandLine.arguments.dropFirst())
    var deviceSubstring: String?
    var mode: Mode

    switch rest.first {
    case "cycles":
        rest.removeFirst()
        guard !rest.isEmpty, let n = Int(rest.removeFirst()), n > 0 else {
            emit("!! 'cycles' mode requires a positive integer cycle count as the next argument")
            usageAndExit()
        }
        mode = .cycles(count: n)
    case "watch":
        rest.removeFirst()
        mode = .watch(duration: 30)
    default:
        mode = .watch(duration: 30)
    }

    var i = 0
    var duration: Double?
    while i < rest.count {
        switch rest[i] {
        case "--device":
            guard i + 1 < rest.count else {
                emit("!! --device requires a value")
                usageAndExit()
            }
            deviceSubstring = rest[i + 1]
            i += 1
        default:
            if duration == nil, let d = Double(rest[i]) {
                duration = d
            }
        }
        i += 1
    }

    if case .watch = mode, let duration {
        mode = .watch(duration: duration)
    }

    return Args(mode: mode, deviceSubstring: deviceSubstring)
}

// MARK: - Main

emit("=== silence-probe-spike (pid=\(getpid())) ===")

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
    emit("!! microphone not authorized — grant access and re-run")
    exit(1)
}

private let args = parseArgs()
private let pinnedDeviceID = resolvePinnedDevice(substring: args.deviceSubstring)

switch args.mode {
case .watch(let duration):
    runWatchMode(pinnedDeviceID: pinnedDeviceID, duration: duration)
case .cycles(let count):
    runCyclesMode(pinnedDeviceID: pinnedDeviceID, cycleCount: count)
}
