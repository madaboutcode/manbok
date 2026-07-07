import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

// Spike: does a browser's VoiceProcessingIO (VPIO) audio unit — created for WebRTC echo
// cancellation during a Meet/Zoom call — gate the raw HAL input stream so that ANOTHER
// process's plain AVAudioEngine tap on the built-in mic reads all-zero samples?
//
// This reproduces the mechanism synthetically with two roles in one binary:
//   --role vpio   fakes the browser: a full-duplex VoiceProcessingIO unit (output element 0
//                 rendering silence, input element 1 capturing mic via AudioUnitRender).
//   --role tap    fakes manbok: AVAudioEngine.inputNode.installTap, mirroring
//                 Sources/ManbokPlatform/Capture/AVAudioCapture.swift.
//
// Run each role in its own process (shell job control), NOT threads in one process — the
// whole point is cross-process AU contention, which in-process would not exercise.
//
//   cd spikes && swift run vpio-contention-spike <seconds> --role vpio
//   cd spikes && swift run vpio-contention-spike <seconds> --role tap
//   cd spikes && swift run vpio-contention-spike <seconds> --role tap --restart-on-stall
//
// --restart-on-stall (tap role only) mirrors CaptureOrchestrator's self-healing watchdog: if no
// tap callback lands for >=4s, tear down and recreate the engine (production's exact F2
// contract — fresh AVAudioEngine per session), up to 5 restarts spaced >=1s apart. The tap role
// also always registers an AVAudioEngineConfigurationChange observer (logged only, not wired to
// a restart trigger) to check whether production's other self-heal signal would even fire.
//
// Both roles print one line per second:
//   [vpio] t=Ns rms=-42.1dBFS rawPeak=0.0123 exactZero=false callbacks=97
//   [tap]  t=Ns rms=-41.8dBFS rawPeak=0.0119 exactZero=false callbacks=94
//
// exactZero means every sample rendered that second was the literal float 0.0 — that is the
// contention signal we're hunting, distinct from ordinary quiet room noise (which reads as a
// low but nonzero RMS, e.g. -50dBFS, not exactZero=true).

// MARK: - Timestamp / logging (copied style from PinnedCaptureSpike)

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

private func dbfs(fromRMS rms: Float) -> Float {
    guard rms > 0 else { return -120 }
    let db = 20 * log10(rms)
    return max(db, -120)
}

// MARK: - Device helpers (minimal subset copied from PinnedCaptureSpike)

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

// MARK: - Per-second stats accumulator, shared shape by both roles.
//
// Callback counting is separate from sample accumulation: a single audio callback can hand us
// multiple channels' worth of samples (tap role, if the hardware format is multichannel), and
// we want "callbacks=<n>" to mean "how many times the audio callback fired", not "how many
// channel buffers we summed".

private final class SecondStats {
    private let lock = NSLock()
    private var callbackCount = 0
    private var sumSquares: Double = 0
    private var sampleCount: Int = 0
    private var peak: Float = 0
    private var sawSample = false
    private var allZero = true
    private var lastRenderErrorStatus: OSStatus?
    private var renderErrorChanged = false
    private var lastCallbackAt: Date?

    func beginCallback() {
        lock.lock()
        defer { lock.unlock() }
        callbackCount += 1
        lastCallbackAt = Date()
    }

    /// Time since the last callback landed, independent of the per-second drain window —
    /// used by the tap role's stall watchdog, which needs to see a stall span multiple
    /// per-second ticks, not just "zero callbacks this second".
    func timeSinceLastCallback() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastCallbackAt else { return nil }
        return Date().timeIntervalSince(last)
    }

    func addSamples(_ samples: UnsafePointer<Float32>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        sawSample = true
        for i in 0..<count {
            let s = samples[i]
            sumSquares += Double(s) * Double(s)
            if s != 0 { allZero = false }
            let a = abs(s)
            if a > peak { peak = a }
        }
        sampleCount += count
    }

    /// Records an OSStatus surfaced from inside a real-time callback (e.g. AudioUnitRender
    /// failing). Only flags a change when the status differs from the last one seen.
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

    func drainSecond() -> (callbacks: Int, rmsDbfs: Float, peak: Float, exactZero: Bool) {
        lock.lock()
        defer {
            callbackCount = 0
            sumSquares = 0
            sampleCount = 0
            peak = 0
            sawSample = false
            allZero = true
            lock.unlock()
        }
        let rms: Float = sampleCount > 0 ? Float(sqrt(sumSquares / Double(sampleCount))) : 0
        // exactZero only means something if we actually saw samples this second — no callbacks
        // at all is a stall, not a zero signal, and is visible separately via callbacks=0.
        let exactZero = sawSample && allZero
        return (callbackCount, dbfs(fromRMS: rms), peak, exactZero)
    }
}

// MARK: - Role: vpio (fake browser) — full-duplex VoiceProcessingIO unit

private enum VPIOError: Error, CustomStringConvertible {
    case componentNotFound
    case osStatus(String, OSStatus)

    var description: String {
        switch self {
        case .componentNotFound: return "AudioComponentFindNext found no kAudioUnitSubType_VoiceProcessingIO component"
        case .osStatus(let call, let status): return "\(call) failed: \(fourCC(status))"
        }
    }
}

private final class VPIORunner {
    private(set) var audioUnit: AudioUnit?
    private var streamFormat = AudioStreamBasicDescription()
    private var bufferList: UnsafeMutableAudioBufferListPointer?
    private let stats: SecondStats
    private let maxFrames: UInt32 = 4096

    init(stats: SecondStats) {
        self.stats = stats
    }

    func start() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw VPIOError.componentNotFound
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else { throw VPIOError.osStatus("AudioComponentInstanceNew", status) }
        audioUnit = unit

        // Enable input (mic) on element 1 — same convention AUHAL uses.
        var one: UInt32 = 1
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw VPIOError.osStatus("EnableIO(input, element 1)", status) }

        // Keep output (speaker) enabled on element 0 — VPIO's AEC needs a live output path to
        // reference against; a real WebRTC call always has one even when the remote side is
        // silent. We supply silence via a render callback rather than disabling this element.
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw VPIOError.osStatus("EnableIO(output, element 0)", status) }

        // Deliberately NOT setting kAudioOutputUnitProperty_CurrentDevice — VPIO always rides
        // the system default input/output, and pinning it would not be representative of the
        // incident we're reproducing (a real browser doesn't pin either).

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, &formatSize)
        guard status == noErr else { throw VPIOError.osStatus("GetStreamFormat(output, element 1)", status) }
        streamFormat = format
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        emit("vpio: input client stream format = \(Int(format.mSampleRate))Hz \(format.mChannelsPerFrame)ch float=\(isFloat) bits=\(format.mBitsPerChannel) interleaved=\(!isNonInterleaved)")

        var maxFramesVar = maxFrames
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFramesVar, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw VPIOError.osStatus("MaximumFramesPerSlice", status) }

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

        // Render callback for the OUTPUT element (bus 0, scope Input — this is where the app
        // supplies data that gets sent to hardware output). We zero the buffers: silent audio,
        // full-duplex unit.
        var outputCallback = AURenderCallbackStruct(
            inputProc: vpioOutputRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &outputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw VPIOError.osStatus("SetRenderCallback(output element 0)", status) }

        // Input callback (global, element 0) — fires when mic data is ready; we pull it via
        // AudioUnitRender against the INPUT element (bus 1) inside handleInput.
        var inputCallback = AURenderCallbackStruct(
            inputProc: vpioInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw VPIOError.osStatus("SetInputCallback", status) }

        status = AudioUnitInitialize(unit)
        guard status == noErr else { throw VPIOError.osStatus("AudioUnitInitialize", status) }

        status = AudioOutputUnitStart(unit)
        guard status == noErr else { throw VPIOError.osStatus("AudioOutputUnitStart", status) }
    }

    fileprivate func handleOutputRender(ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        for buffer in list {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        return noErr
    }

    fileprivate func handleInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        numberFrames: UInt32
    ) -> OSStatus {
        guard let unit = audioUnit, let bufferList else { return -50 } // paramErr

        stats.beginCallback()

        let isNonInterleaved = (streamFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerChannelFrame: UInt32 = isNonInterleaved
            ? UInt32(streamFormat.mBitsPerChannel / 8)
            : streamFormat.mBytesPerFrame
        for i in 0..<bufferList.count {
            bufferList[i].mDataByteSize = numberFrames * bytesPerChannelFrame
        }

        let status = AudioUnitRender(unit, ioActionFlags, timeStamp, 1, numberFrames, bufferList.unsafeMutablePointer)
        guard status == noErr else {
            stats.recordRenderError(status)
            return status
        }

        let isFloat = (streamFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = Int(streamFormat.mBitsPerChannel)
        for buffer in bufferList {
            guard let data = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            if isFloat, bitsPerChannel == 32 {
                let count = byteCount / MemoryLayout<Float32>.size
                let ptr = data.bindMemory(to: Float32.self, capacity: count)
                stats.addSamples(ptr, count: count)
            } else if !isFloat, bitsPerChannel == 16 {
                let count = byteCount / MemoryLayout<Int16>.size
                let ptr = data.bindMemory(to: Int16.self, capacity: count)
                var floats = [Float32](repeating: 0, count: count)
                for i in 0..<count { floats[i] = Float32(ptr[i]) / 32768.0 }
                floats.withUnsafeBufferPointer { buf in
                    if let base = buf.baseAddress {
                        stats.addSamples(base, count: count)
                    }
                }
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

/// C trampoline for the output element's render callback (kAudioUnitProperty_SetRenderCallback).
private func vpioOutputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let runner = Unmanaged<VPIORunner>.fromOpaque(inRefCon).takeUnretainedValue()
    return runner.handleOutputRender(ioData: ioData)
}

/// C trampoline for kAudioOutputUnitProperty_SetInputCallback.
private func vpioInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let runner = Unmanaged<VPIORunner>.fromOpaque(inRefCon).takeUnretainedValue()
    return runner.handleInput(ioActionFlags: ioActionFlags, timeStamp: inTimeStamp, numberFrames: inNumberFrames)
}

// MARK: - Role: tap (fake manbok) — mirrors Sources/ManbokPlatform/Capture/AVAudioCapture.swift

private final class TapRunner {
    private var engine: AVAudioEngine?
    private let stats: SecondStats
    private var loggedFirstBuffer = false
    private var loggedUnsupportedFormat = false

    // --restart-on-stall: mirrors CaptureOrchestrator's watchdog
    // (Sources/ManbokPlatform/Capture/CaptureOrchestrator.swift) — "an app holds the mic, so
    // silence means our engine stalled" — restarted via AVAudioCapture's F2 contract (fresh
    // engine per session). CaptureRestartPolicy's real defaults are watchdogThreshold=4.0s,
    // baseDelay=1.0s (Sources/ManbokPlatform/Capture/CaptureRestartPolicy.swift) — same numbers
    // used here, but as a flat threshold/gap rather than the real policy's exponential backoff,
    // since this spike only needs a bounded number of restarts, not indefinite flap protection.
    private let restartOnStall: Bool
    private let stallThreshold: TimeInterval = 4.0
    private let minRestartGap: TimeInterval = 1.0
    private let maxRestarts = 5
    private var restartCount = 0
    private var lastRestartAt: Date?

    var isEngineRunning: Bool { engine?.isRunning ?? false }

    init(stats: SecondStats, restartOnStall: Bool) {
        self.stats = stats
        self.restartOnStall = restartOnStall
    }

    func start() throws {
        let newEngine = AVAudioEngine()
        engine = newEngine
        let input = newEngine.inputNode

        // Mirror AVAudioCapture.start(): pass nil format, let the engine match hardware.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer, inputNode: input)
        }

        try newEngine.start()
    }

    private func handleTap(buffer: AVAudioPCMBuffer, inputNode: AVAudioInputNode) {
        stats.beginCallback()

        if !loggedFirstBuffer {
            loggedFirstBuffer = true
            let format = buffer.format
            let device = Self.actualInputDevice(inputNode)
            emit("tap: first buffer format=\(format.sampleRate)Hz ch=\(format.channelCount) commonFormat=\(format.commonFormat.rawValue) frames=\(buffer.frameLength) device=\(device)")
        }

        guard let channelData = buffer.floatChannelData else {
            if !loggedUnsupportedFormat {
                loggedUnsupportedFormat = true
                emit("!! tap: buffer.floatChannelData is nil (non-float hardware format?) — RMS/exactZero will read 0 for these buffers")
            }
            return
        }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        for ch in 0..<channelCount {
            stats.addSamples(channelData[ch], count: frameLength)
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// Called once per second from the main timer. Checks whether tap callbacks have stopped
    /// for >= stallThreshold and, if so, restarts — up to maxRestarts, spaced >= minRestartGap
    /// apart. No-op unless --restart-on-stall was passed.
    func checkWatchdogIfNeeded() {
        guard restartOnStall, restartCount < maxRestarts else { return }
        guard let sinceLast = stats.timeSinceLastCallback(), sinceLast >= stallThreshold else { return }
        let now = Date()
        if let last = lastRestartAt, now.timeIntervalSince(last) < minRestartGap { return }
        restartCount += 1
        lastRestartAt = now
        emit("RESTART #\(restartCount) — no tap callbacks for \(String(format: "%.1f", sinceLast))s")
        performRestart()
    }

    /// Exactly what production's restartCapture -> startCapture does on a watchdog trip: stop
    /// (removeTap + engine.stop()), discard the engine object, then create a brand-new
    /// AVAudioEngine + tap + start — AVAudioCapture's F2 contract is a fresh engine per session,
    /// never a reused one.
    private func performRestart() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        loggedFirstBuffer = false
        do {
            try start()
            emit("RESTART #\(restartCount) succeeded")
        } catch {
            emit("!! RESTART #\(restartCount) failed: \(error)")
        }
    }

    /// Mirrors AVAudioCapture.actualInputDevice — reads kAudioOutputUnitProperty_CurrentDevice
    /// off the tap's underlying AudioUnit to show which HAL device the tap is actually bound to.
    private static func actualInputDevice(_ inputNode: AVAudioInputNode) -> String {
        guard let au = inputNode.audioUnit else { return "no audio unit" }
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, &size)
        guard status == noErr else { return "query failed OSStatus=\(fourCC(status))" }
        return deviceLabel(deviceID)
    }
}

// MARK: - CLI args

private enum Role: String {
    case vpio
    case tap
}

private struct Args {
    var duration: Double = 15
    var role: Role?
    var restartOnStall = false
}

private func usageAndExit() -> Never {
    emit("!! usage: vpio-contention-spike [seconds] --role vpio|tap [--restart-on-stall]")
    exit(1)
}

private func parseArgs() -> Args {
    var args = Args()
    let rest = Array(CommandLine.arguments.dropFirst())
    var positionalConsumed = false
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--role":
            guard i + 1 < rest.count, let role = Role(rawValue: rest[i + 1]) else {
                emit("!! --role requires a value of 'vpio' or 'tap'")
                usageAndExit()
            }
            args.role = role
            i += 1
        case "--restart-on-stall":
            args.restartOnStall = true
        default:
            if !positionalConsumed, let d = Double(rest[i]) {
                args.duration = d
                positionalConsumed = true
            }
        }
        i += 1
    }
    guard args.role != nil else {
        emit("!! --role is required")
        usageAndExit()
    }
    return args
}

// MARK: - Main

emit("=== vpio-contention-spike ===")
let ownPID = getpid()
private let args = parseArgs()
private let role = args.role!
emit("pid=\(ownPID) duration=\(Int(args.duration))s role=\(role.rawValue)")

let defaultInputLabel = defaultInputID().map { deviceLabel($0) } ?? "unknown"
emit("default input device: \(defaultInputLabel)")

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

private let stats = SecondStats()
private var vpioRunner: VPIORunner?
private var tapRunner: TapRunner?

do {
    switch role {
    case .vpio:
        let runner = VPIORunner(stats: stats)
        try runner.start()
        vpioRunner = runner
        emit("vpio: AudioOutputUnitStart succeeded")
    case .tap:
        let runner = TapRunner(stats: stats, restartOnStall: args.restartOnStall)
        try runner.start()
        tapRunner = runner
        emit("tap: engine.start() succeeded restartOnStall=\(args.restartOnStall)")
    }
} catch {
    emit("!! \(role.rawValue) start failed: \(error)")
    exit(1)
}

// MARK: AVAudioEngineConfigurationChange — observational only. Production
// (CaptureOrchestrator.start()) wires this into a restart trigger; here we only log arrival +
// engine.isRunning at that moment, to answer whether production's observer would even SEE a
// stall like the one phase 3 found. object: nil catches the notification regardless of which
// engine instance (including engines created by TapRunner's own restarts) posted it — same as
// production's rationale for object: nil.
private var configChangeObserverToken: NSObjectProtocol?
if role == .tap {
    configChangeObserverToken = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange,
        object: nil,
        queue: nil
    ) { _ in
        let runningNow = tapRunner?.isEngineRunning ?? false
        emit("!! AVAudioEngineConfigurationChange fired — engine.isRunning=\(runningNow)")
    }
}

private func stopActive() {
    vpioRunner?.stop()
    tapRunner?.stop()
    if let token = configChangeObserverToken {
        NotificationCenter.default.removeObserver(token)
        configChangeObserverToken = nil
    }
}

// MARK: SIGINT — clean shutdown

signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    emit("=== SIGINT — cleaning up ===")
    stopActive()
    exit(0)
}
sigintSource.resume()

// MARK: Timer — 1s summary, driven from RunLoop.main

let startTime = Date()
var elapsedSeconds = 0
let tag = "[\(role.rawValue)]"

let summaryTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
summaryTimer.schedule(deadline: .now() + 1, repeating: 1)
summaryTimer.setEventHandler {
    elapsedSeconds += 1
    let (callbacks, rms, peak, exactZero) = stats.drainSecond()
    emit("\(tag) t=\(elapsedSeconds)s rms=\(String(format: "%.1f", rms))dBFS rawPeak=\(String(format: "%.4f", peak)) exactZero=\(exactZero) callbacks=\(callbacks)")

    let (changed, status) = stats.drainRenderErrorChange()
    if changed, let status {
        emit("!! \(role.rawValue): AudioUnitRender status changed to \(fourCC(status))")
    }

    tapRunner?.checkWatchdogIfNeeded()

    if elapsedSeconds >= Int(args.duration) {
        emit("=== done (\(Int(args.duration))s) — cleaning up ===")
        stopActive()
        exit(0)
    }
}
summaryTimer.resume()

RunLoop.main.run()
