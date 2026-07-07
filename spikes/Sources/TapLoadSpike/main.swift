import AVFoundation
import Darwin
import Foundation

// Spike: how loaded can the AVAudioEngine tap thread / its sink queue get before we start
// dropping audio?
//
// Incident this spike investigates: production (AVAudioCapture.handleTap ->
// CaptureOrchestrator -> SessionRegistry.append) delivers every tap buffer into a registry via
// `queue.sync` on a single serial DispatchQueue. That same queue also serves large ring-buffer
// copies (~19MB typical for a 10-min ring, up to ~230MB for the 120-min preset) for
// checkpoint/dump operations. A design review claims this risks blocking the tap thread and
// dropping audio. This spike measures, it does not guess:
//
//   --mode thread : what thread/QoS does the tap callback actually run on?
//   --mode stall  : inject checkpoint-sized memcpy stalls onto the same serial queue the tap
//                   uses, and measure inter-callback gaps + estimated frame loss.
//   --mode retain : does AVAudioEngine reuse/overwrite a tap's AVAudioPCMBuffer shortly after
//                   the callback returns? Decides copy-in-tap vs. retain-and-process-async.
//
// Run:
//   cd spikes && swift run tap-load-spike 10 --mode thread
//   cd spikes && swift run tap-load-spike 30 --mode stall
//   cd spikes && swift run tap-load-spike 10 --mode retain

// MARK: - Timestamp / logging (style matches PinnedCaptureSpike)

private func ts() -> String {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss.SSS"
    return df.string(from: Date())
}

private func emit(_ msg: String) {
    print("[\(ts())] \(msg)")
    fflush(stdout)
}

// MARK: - mach_absolute_time -> ns

private let timebaseInfo: mach_timebase_info = {
    var info = mach_timebase_info()
    mach_timebase_info(&info)
    return info
}()

private func nowNs() -> UInt64 {
    mach_absolute_time() * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
}

// MARK: - SIGINT handling (clean engine stop on Ctrl-C, all modes)

@discardableResult
private func installSigintHandler(_ handler: @escaping () -> Void) -> DispatchSourceSignal {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler(handler: handler)
    source.resume()
    return source
}

// MARK: - Descriptive helpers for thread/format identity

private func describeQoS(_ qos: qos_class_t) -> String {
    switch qos {
    case QOS_CLASS_USER_INTERACTIVE: return "USER_INTERACTIVE"
    case QOS_CLASS_USER_INITIATED: return "USER_INITIATED"
    case QOS_CLASS_DEFAULT: return "DEFAULT"
    case QOS_CLASS_UTILITY: return "UTILITY"
    case QOS_CLASS_BACKGROUND: return "BACKGROUND"
    case QOS_CLASS_UNSPECIFIED: return "UNSPECIFIED"
    default: return "UNKNOWN(\(qos.rawValue))"
    }
}

private func describeQualityOfService(_ qos: QualityOfService) -> String {
    switch qos {
    case .userInteractive: return "userInteractive"
    case .userInitiated: return "userInitiated"
    case .default: return "default"
    case .utility: return "utility"
    case .background: return "background"
    @unknown default: return "unknown"
    }
}

private func describeCommonFormat(_ fmt: AVAudioCommonFormat) -> String {
    switch fmt {
    case .pcmFormatFloat32: return "float32"
    case .pcmFormatFloat64: return "float64"
    case .pcmFormatInt16: return "int16"
    case .pcmFormatInt32: return "int32"
    case .otherFormat: return "other"
    @unknown default: return "unknown"
    }
}

// MARK: - Mic permission (same pattern as PinnedCaptureSpike)

private func ensureMicAuthorized() {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return
    case .notDetermined:
        let sem = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { _ in sem.signal() }
        sem.wait()
    default:
        emit("!! microphone not authorized — grant access and re-run")
        exit(1)
    }
}

// MARK: - Mode 1: thread — identify the tap callback's thread/QoS

private final class OnceGate {
    private let lock = NSLock()
    private var fired = false
    func fireOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

private final class Counter {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private func runThreadMode(duration: Double) {
    emit("=== tap-load-spike --mode thread (duration=\(Int(duration))s) ===")

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let identityGate = OnceGate()
    let callbackCount = Counter()

    input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
        callbackCount.increment()
        guard identityGate.fireOnce() else { return }

        var nameBuf = [CChar](repeating: 0, count: 64)
        pthread_getname_np(pthread_self(), &nameBuf, nameBuf.count)
        let pthreadName = String(cString: nameBuf)

        let qos = qos_class_self()
        let format = buffer.format
        let frameLength = buffer.frameLength
        let sampleRate = format.sampleRate
        let expectedIntervalMs = sampleRate > 0 ? (Double(frameLength) / sampleRate) * 1000 : 0

        emit("--- TAP THREAD IDENTITY (first callback) ---")
        emit("  pthread name: \"\(pthreadName)\"\(pthreadName.isEmpty ? " (empty — unnamed thread)" : "")")
        emit("  qos_class_self(): \(describeQoS(qos))")
        emit("  Thread.isMainThread: \(Thread.isMainThread)")
        emit("  Thread.current.threadPriority: \(Thread.current.threadPriority)")
        emit("  Thread.current.qualityOfService: \(describeQualityOfService(Thread.current.qualityOfService))")
        emit("  buffer: frameLength=\(frameLength) format=\(Int(format.sampleRate))Hz ch=\(format.channelCount) commonFormat=\(describeCommonFormat(format.commonFormat))")
        emit("  expected interval per buffer = frameLength/sampleRate = \(String(format: "%.2f", expectedIntervalMs))ms")
    }

    do {
        try engine.start()
    } catch {
        emit("!! engine.start() failed: \(error)")
        exit(1)
    }
    emit("engine started, tapping input...")

    func cleanupAndExit() -> Never {
        input.removeTap(onBus: 0)
        engine.stop()
        exit(0)
    }

    installSigintHandler {
        emit("=== SIGINT — cleaning up ===")
        cleanupAndExit()
    }

    var elapsed = 0
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        elapsed += 1
        emit("[t=\(elapsed)s] callbacks so far=\(callbackCount.value)")
        if elapsed >= Int(duration) {
            emit("=== done (\(Int(duration))s) — cleaning up ===")
            cleanupAndExit()
        }
    }
    timer.resume()
    RunLoop.main.run()
}

// MARK: - Mode 2: stall — inject checkpoint-sized memcpy stalls onto the tap's sink queue

/// Fixed-capacity byte ring, written via memcpy at a wrapping position — stand-in for
/// SessionRegistry's `ByteRingBuffer.write`.
private final class RingScratch {
    let capacity: Int
    private let base: UnsafeMutableRawPointer
    private var writePos = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.base = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        memset(base, 0, capacity)
    }

    func write(_ src: UnsafeRawPointer, count: Int) {
        let n = min(count, capacity)
        if writePos + n <= capacity {
            memcpy(base + writePos, src, n)
            writePos += n
            if writePos == capacity { writePos = 0 }
        } else {
            let firstPart = capacity - writePos
            memcpy(base + writePos, src, firstPart)
            memcpy(base, src + firstPart, n - firstPart)
            writePos = n - firstPart
        }
    }

    deinit { base.deallocate() }
}

/// malloc-based allocation (recoverable failure, unlike Swift's `allocate(byteCount:)` which
/// traps) so the 230MB buffer can fall back to 100MB per the spike's stop conditions. Fills the
/// buffer once so pages are actually committed before timing starts — otherwise the first
/// memcpy touching untouched zero pages would look artificially fast/slow vs. steady state.
private func allocateFilled(primaryBytes: Int, fallbackBytes: Int, label: String) -> (ptr: UnsafeMutableRawPointer, size: Int) {
    if let ptr = malloc(primaryBytes) {
        memset(ptr, 0xAB, primaryBytes)
        return (ptr, primaryBytes)
    }
    emit("!! allocation of \(primaryBytes / 1_000_000)MB for \(label) failed — falling back to \(fallbackBytes / 1_000_000)MB")
    guard let ptr = malloc(fallbackBytes) else {
        emit("!! fallback allocation of \(fallbackBytes / 1_000_000)MB for \(label) also failed — aborting")
        exit(1)
    }
    memset(ptr, 0xAB, fallbackBytes)
    return (ptr, fallbackBytes)
}

private final class StallStats {
    private let lock = NSLock()
    private var gapsNs: [UInt64] = []
    private var gapEvents: [(atSec: Double, gapMs: Double)] = []
    private var callbackCount = 0
    private var totalFrames: UInt64 = 0
    private var lastArrivalNs: UInt64?
    private(set) var expectedIntervalNs: UInt64 = 0
    private(set) var firstFrameLength: AVAudioFrameCount = 0
    private(set) var firstSampleRate: Double = 0
    var runStartNs: UInt64 = 0

    func recordFirstBufferFormat(frameLength: AVAudioFrameCount, sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard expectedIntervalNs == 0 else { return }
        firstFrameLength = frameLength
        firstSampleRate = sampleRate
        expectedIntervalNs = sampleRate > 0 ? UInt64((Double(frameLength) / sampleRate) * 1_000_000_000) : 0
    }

    func recordArrival(ns: UInt64, frames: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        callbackCount += 1
        totalFrames += frames
        if let last = lastArrivalNs {
            let gap = ns - last
            gapsNs.append(gap)
            if expectedIntervalNs > 0, Double(gap) > Double(expectedIntervalNs) * 1.5 {
                let atSec = Double(ns - runStartNs) / 1_000_000_000
                gapEvents.append((atSec: atSec, gapMs: Double(gap) / 1_000_000))
            }
        }
        lastArrivalNs = ns
    }

    func snapshot() -> (count: Int, totalFrames: UInt64, gapsNs: [UInt64], gapEvents: [(atSec: Double, gapMs: Double)]) {
        lock.lock(); defer { lock.unlock() }
        return (callbackCount, totalFrames, gapsNs, gapEvents)
    }
}

private func memcpyStallJob(label: String, queue: DispatchQueue, src: UnsafeMutableRawPointer, dst: UnsafeMutableRawPointer, byteCount: Int, iterations: Int) {
    queue.async {
        let jobStart = nowNs()
        emit("STALL JOB START: \(label) (\(iterations)x \(byteCount / 1_000_000)MB memcpy)")
        for _ in 0..<iterations {
            memcpy(dst, src, byteCount)
        }
        let jobEnd = nowNs()
        emit("STALL JOB END:   \(label) duration=\(String(format: "%.1f", Double(jobEnd - jobStart) / 1_000_000))ms")
    }
}

private func runStallMode(duration: Double) {
    emit("=== tap-load-spike --mode stall (duration=\(Int(duration))s) ===")

    // Ring scratch sized like the 10-min preset (AudioFormat.capacityBytes = 19_200_000).
    let ringScratch = RingScratch(capacity: 19_200_000)

    // "19MB" stall pair: same size as the ring — stands in for a checkpoint copying the whole ring.
    let (src19, size19) = allocateFilled(primaryBytes: 19_200_000, fallbackBytes: 19_200_000, label: "19MB stall source")
    let (dst19, _) = allocateFilled(primaryBytes: size19, fallbackBytes: size19, label: "19MB stall dest")

    // "230MB" stall pair: 120-min preset (16000 * 2 bytes * 7200s = 230_400_000). Falls back to
    // 100MB per the spike's stop conditions if that allocation fails.
    let (src230, size230) = allocateFilled(primaryBytes: 230_400_000, fallbackBytes: 100_000_000, label: "230MB stall source")
    let (dst230, _) = allocateFilled(primaryBytes: size230, fallbackBytes: size230, label: "230MB stall dest")

    let registryQueue = DispatchQueue(label: "registry-sim") // serial, mirrors SessionRegistry's queue
    let stats = StallStats()
    let runStart = nowNs()
    stats.runStartNs = runStart

    let engine = AVAudioEngine()
    let input = engine.inputNode

    input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
        let arrivalNs = nowNs()
        stats.recordFirstBufferFormat(frameLength: buffer.frameLength, sampleRate: buffer.format.sampleRate)
        stats.recordArrival(ns: arrivalNs, frames: UInt64(buffer.frameLength))

        // Mirror SessionRegistry.append: queue.sync { ring.write(data) } — memcpy the tap's raw
        // delivered bytes into the ring scratch under the same serial queue the stall jobs use.
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let src = audioBuffer.mData else { return }
        let byteCount = Int(audioBuffer.mDataByteSize)
        registryQueue.sync {
            ringScratch.write(src, count: byteCount)
        }
    }

    do {
        try engine.start()
    } catch {
        emit("!! engine.start() failed: \(error)")
        exit(1)
    }
    emit("engine started, tapping input; registry-sim queue shared with stall jobs...")

    func cleanupAndExit() -> Never {
        input.removeTap(onBus: 0)
        engine.stop()
        free(src19); free(dst19); free(src230); free(dst230)
        exit(0)
    }

    installSigintHandler {
        emit("=== SIGINT — cleaning up ===")
        cleanupAndExit()
    }

    // Background thread injects stalls onto registryQueue at fixed wall-clock offsets.
    let stallInjector = DispatchQueue(label: "stall-injector")
    stallInjector.async {
        let start = Date()
        func waitUntil(_ offsetSec: Double) {
            let remaining = start.addingTimeInterval(offsetSec).timeIntervalSinceNow
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        }
        waitUntil(5)
        memcpyStallJob(label: "t=5s 19MBx1", queue: registryQueue, src: src19, dst: dst19, byteCount: size19, iterations: 1)
        waitUntil(10)
        memcpyStallJob(label: "t=10s 19MBx5", queue: registryQueue, src: src19, dst: dst19, byteCount: size19, iterations: 5)
        waitUntil(15)
        memcpyStallJob(label: "t=15s 230MBx1", queue: registryQueue, src: src230, dst: dst230, byteCount: size230, iterations: 1)
        waitUntil(20)
        memcpyStallJob(label: "t=20s 230MBx3", queue: registryQueue, src: src230, dst: dst230, byteCount: size230, iterations: 3)
    }

    var elapsed = 0
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        elapsed += 1
        let snap = stats.snapshot()
        emit("[t=\(elapsed)s] callbacks so far=\(snap.count) framesReceived=\(snap.totalFrames)")
        if elapsed >= Int(duration) {
            emit("=== done (\(Int(duration))s) — summarizing ===")
            let final = stats.snapshot()
            let sortedGaps = final.gapsNs.sorted()
            func ms(_ ns: UInt64) -> Double { Double(ns) / 1_000_000 }
            let minGap = sortedGaps.first.map(ms) ?? 0
            let maxGap = sortedGaps.last.map(ms) ?? 0
            let medianGap = sortedGaps.isEmpty ? 0 : ms(sortedGaps[sortedGaps.count / 2])
            let expectedMs = Double(stats.expectedIntervalNs) / 1_000_000

            emit("=== STALL MODE SUMMARY ===")
            emit("expected interval: \(String(format: "%.2f", expectedMs))ms (frameLength=\(stats.firstFrameLength) sampleRate=\(Int(stats.firstSampleRate))Hz)")
            emit("callbacks: \(final.count)")
            emit("gap min/median/max: \(String(format: "%.2f", minGap))ms / \(String(format: "%.2f", medianGap))ms / \(String(format: "%.2f", maxGap))ms")
            emit("gaps > 1.5x expected (\(final.gapEvents.count) total):")
            for ev in final.gapEvents {
                emit("  t=\(String(format: "%.2f", ev.atSec))s gap=\(String(format: "%.1f", ev.gapMs))ms")
            }
            let expectedFrames = duration * stats.firstSampleRate
            let framesLost = expectedFrames - Double(final.totalFrames)
            let pctLost = expectedFrames > 0 ? (framesLost / expectedFrames) * 100 : 0
            emit("frames-lost estimate: expected=\(Int(expectedFrames)) received=\(final.totalFrames) lost=\(Int(framesLost)) (\(String(format: "%.3f", pctLost))%)")

            cleanupAndExit()
        }
    }
    timer.resume()
    RunLoop.main.run()
}

// MARK: - Mode 3: retain — does AVAudioEngine reuse/overwrite a retained tap buffer?

private struct RetainedEntry {
    let index: Int
    let buffer: AVAudioPCMBuffer
    let capturedChecksum: Double
    let immediateCopy: Data
    let frameLength: AVAudioFrameCount
}

private final class RetainStore {
    private let lock = NSLock()
    private var entries: [RetainedEntry] = []
    func append(_ entry: RetainedEntry) {
        lock.lock(); entries.append(entry); lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}

private final class RetainStats {
    private let lock = NSLock()
    private var checked = 0
    private var matches = 0
    private var mismatches = 0

    func recordMatch() { lock.lock(); checked += 1; matches += 1; lock.unlock() }
    func recordMismatch() { lock.lock(); checked += 1; mismatches += 1; lock.unlock() }
    func snapshot() -> (checked: Int, matches: Int, mismatches: Int) {
        lock.lock(); defer { lock.unlock() }
        return (checked, matches, mismatches)
    }
}

private func checksum(of channelData: UnsafePointer<UnsafeMutablePointer<Float>>, frameLength: AVAudioFrameCount) -> Double {
    let n = min(Int(frameLength), 256)
    var sum: Double = 0
    for i in 0..<n { sum += Double(channelData[0][i]) }
    return sum + Double(frameLength)
}

private func runRetainMode(duration: Double) {
    emit("=== tap-load-spike --mode retain (duration=\(Int(duration))s) ===")

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let store = RetainStore()
    let stats = RetainStats()
    let recheckQueue = DispatchQueue(label: "retain-recheck")
    var nextIndex = 0
    let indexLock = NSLock()

    input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = buffer.frameLength
        let capturedChecksum = checksum(of: channelData, frameLength: frameLength)
        let byteCount = Int(frameLength) * MemoryLayout<Float>.size
        let immediateCopy = Data(bytes: channelData[0], count: byteCount)

        indexLock.lock()
        let idx = nextIndex
        nextIndex += 1
        indexLock.unlock()

        let entry = RetainedEntry(index: idx, buffer: buffer, capturedChecksum: capturedChecksum, immediateCopy: immediateCopy, frameLength: frameLength)
        store.append(entry)

        let delay = Double.random(in: 0.5...2.0)
        recheckQueue.asyncAfter(deadline: .now() + delay) {
            guard let currentChannelData = entry.buffer.floatChannelData else {
                emit("!! RETAIN MISMATCH: entry \(entry.index) — buffer.floatChannelData became nil after \(String(format: "%.2f", delay))s")
                stats.recordMismatch()
                return
            }
            let recomputed = checksum(of: currentChannelData, frameLength: entry.frameLength)
            let checksumMatches = recomputed == entry.capturedChecksum
            let currentByteCount = Int(entry.frameLength) * MemoryLayout<Float>.size
            let currentBytes = Data(bytes: currentChannelData[0], count: currentByteCount)
            let bytesMatchImmediateCopy = currentBytes == entry.immediateCopy

            if checksumMatches, bytesMatchImmediateCopy {
                stats.recordMatch()
            } else {
                emit("!! RETAIN MISMATCH: entry \(entry.index) checksumMatch=\(checksumMatches) bytesMatchImmediateCopy=\(bytesMatchImmediateCopy) delay=\(String(format: "%.2f", delay))s")
                stats.recordMismatch()
            }
        }
    }

    do {
        try engine.start()
    } catch {
        emit("!! engine.start() failed: \(error)")
        exit(1)
    }
    emit("engine started, tapping input; rechecking retained buffers 0.5-2.0s later...")

    func cleanupAndExit() -> Never {
        input.removeTap(onBus: 0)
        engine.stop()
        let snap = stats.snapshot()
        emit("=== RETAIN MODE SUMMARY ===")
        emit("buffers stored: \(store.count)")
        emit("buffers checked: \(snap.checked)")
        emit("matches (retained buffer content stable): \(snap.matches)")
        emit("mismatches (retained buffer reused/overwritten): \(snap.mismatches)")
        if snap.checked < store.count {
            emit("note: \(store.count - snap.checked) buffers had their recheck still pending at exit — grace window may be too short")
        }
        exit(0)
    }

    installSigintHandler {
        emit("=== SIGINT — cleaning up ===")
        cleanupAndExit()
    }

    var elapsed = 0
    // Extra grace so the last buffer's recheck (max 2.0s delay) has time to land before summary.
    let graceSeconds = 2.5
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        elapsed += 1
        emit("[t=\(elapsed)s] buffers stored so far=\(store.count) checked so far=\(stats.snapshot().checked)")
        if Double(elapsed) >= duration + graceSeconds {
            cleanupAndExit()
        } else if Double(elapsed) == duration {
            emit("tap window closed at t=\(elapsed)s, waiting \(graceSeconds)s grace for pending rechecks...")
            input.removeTap(onBus: 0)
        }
    }
    timer.resume()
    RunLoop.main.run()
}

// MARK: - CLI args

private enum Mode: String {
    case thread
    case stall
    case retain
}

private struct Args {
    var duration: Double = 10
    var mode: Mode?
}

private func usageAndExit() -> Never {
    emit("!! usage: tap-load-spike <seconds> --mode thread|stall|retain")
    exit(1)
}

private func parseArgs() -> Args {
    var args = Args()
    let rest = Array(CommandLine.arguments.dropFirst())
    var positionalConsumed = false
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--mode":
            guard i + 1 < rest.count, let mode = Mode(rawValue: rest[i + 1]) else {
                emit("!! --mode requires a value of 'thread', 'stall', or 'retain'")
                usageAndExit()
            }
            args.mode = mode
            i += 1
        default:
            if !positionalConsumed, let d = Double(rest[i]) {
                args.duration = d
                positionalConsumed = true
            }
        }
        i += 1
    }
    guard args.mode != nil else {
        emit("!! --mode is required")
        usageAndExit()
    }
    return args
}

// MARK: - Main

emit("=== tap-load-spike ===")
private let args = parseArgs()
emit("pid=\(getpid()) duration=\(Int(args.duration))s mode=\(args.mode!.rawValue)")

ensureMicAuthorized()

switch args.mode! {
case .thread: runThreadMode(duration: args.duration)
case .stall: runStallMode(duration: args.duration)
case .retain: runRetainMode(duration: args.duration)
}
