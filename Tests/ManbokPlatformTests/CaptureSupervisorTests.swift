import CoreAudio
import XCTest
@testable import ManbokPlatform

private final class FakeWorker: PinnedAudioCapturing {
    var startTarget: CaptureTarget?
    var sink: ((CaptureChunk) -> Void)?
    var stopped = false
    var startError: PinnedCaptureError?
    private(set) var boundDevice: AudioDeviceID?

    func start(target: CaptureTarget, sink: @escaping (CaptureChunk) -> Void) throws {
        if let error = startError { throw error }
        startTarget = target
        self.sink = sink
        switch target {
        case .systemDefault: boundDevice = 99 // fake default
        case .device(let id): boundDevice = id
        }
    }

    func stop() { stopped = true; sink = nil }

    func deliverChunk(pcm: Data = Data(count: 32000), peak: Int16 = 1000) {
        sink?(CaptureChunk(pcm: pcm, peak: peak))
    }

    func deliverSilence() {
        sink?(CaptureChunk(pcm: Data(count: 32000), peak: 0))
    }
}

private final class FakeSignals: EnvironmentSignaling {
    var handler: ((EnvironmentSignal) -> Void)?
    var activated = false
    var observedDevice: AudioDeviceID?

    func activate() { activated = true }
    func deactivate() { activated = false; handler = nil }
    func observe(device: AudioDeviceID?) { observedDevice = device }

    func send(_ signal: EnvironmentSignal) { handler?(signal) }
}

/// Captures emitted log lines so tests can assert on escalation (e.g. the 3rd
/// consecutive unhealthy restart .error) without touching real os.Logger/stderr.
private final class FakeDiagnosticsSink: DiagnosticsWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _errors: [String] = []
    var errors: [String] { lock.lock(); defer { lock.unlock() }; return _errors }

    func notice(category: AppLog.Category, _ message: String) {}
    func info(category: AppLog.Category, _ message: String) {}
    func warning(category: AppLog.Category, _ message: String) {}
    func error(category: AppLog.Category, _ message: String) {
        lock.lock(); _errors.append(message); lock.unlock()
    }
    func debug(category: AppLog.Category, _ message: String) {}
}

final class CaptureSupervisorTests: XCTestCase {
    private var workers: [FakeWorker]!
    private var workerIndex: Int!
    private var signals: FakeSignals!
    private var appendedData: [Data]!
    private var clockNow: Date!
    private var diagnostics: FakeDiagnosticsSink!

    override func setUp() {
        super.setUp()
        workers = (0..<10).map { _ in FakeWorker() }
        workerIndex = 0
        signals = FakeSignals()
        appendedData = []
        clockNow = Date(timeIntervalSince1970: 1000)
        diagnostics = FakeDiagnosticsSink()
        Diagnostics.install(diagnostics)
    }

    override func tearDown() {
        Diagnostics.install(OSLogAndStderrDiagnostics())
        super.tearDown()
    }

    private func makeSupervisor(
        snapshot: @escaping () -> [AudioProcessInfo] = { [] },
        restartPolicy: CaptureRestartPolicy = .init(watchdogThreshold: 4, baseDelay: 1, maxDelay: 30),
        silencePolicy: SilenceRecoveryPolicy = .init(silenceThreshold: 10, maxSilentRestarts: 2)
    ) -> CaptureSupervisor {
        CaptureSupervisor(
            makeWorker: { [self] in
                let w = workers[workerIndex]
                workerIndex += 1
                return w
            },
            processSnapshot: snapshot,
            signals: signals,
            appendSink: { [self] data in appendedData.append(data) },
            restartPolicy: restartPolicy,
            silencePolicy: silencePolicy,
            clock: { [self] in clockNow }
        )
    }

    private func demand(_ bundleID: String, pid: pid_t = 100, arrived: Date? = nil) -> DemandEntry {
        DemandEntry(bundleID: bundleID, pid: pid, arrivedAt: arrived ?? clockNow)
    }

    private func processInfo(_ bundleID: String, pid: pid_t = 100, devices: [AudioDeviceID] = []) -> AudioProcessInfo {
        AudioProcessInfo(pid: pid, bundleID: bundleID, isRunningInput: true, deviceIDs: devices)
    }

    // MARK: - 1. Worker iff demand

    func test_workerRunsIffDemandNonEmpty() {
        let sup = makeSupervisor()

        let statusEmpty = sup.apply(demand: [], now: clockNow)
        XCTAssertFalse(statusEmpty.isCapturing)
        XCTAssertNil(workers[0].startTarget)

        let statusDemand = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertTrue(statusDemand.isCapturing)
        XCTAssertNotNil(workers[0].startTarget)

        clockNow = clockNow.addingTimeInterval(2)
        let statusStop = sup.apply(demand: [], now: clockNow)
        XCTAssertFalse(statusStop.isCapturing)
        XCTAssertTrue(workers[0].stopped)
    }

    // MARK: - 2. Fresh instance per restart

    func test_freshWorkerInstancePerRestart() {
        var currentDevices: [AudioDeviceID] = [1]
        let sup = makeSupervisor(
            snapshot: { [self] in [processInfo("com.app.a", devices: currentDevices)] },
            restartPolicy: .init(watchdogThreshold: 4, baseDelay: 0, maxDelay: 30)
        )

        _ = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertEqual(workerIndex, 1)
        XCTAssertFalse(workers[0].stopped)

        // Trigger a restart via target mismatch; the new worker must be a distinct
        // instance from the first (never reused).
        currentDevices = [2]
        clockNow = clockNow.addingTimeInterval(1)
        _ = sup.apply(demand: [demand("com.app.a")], now: clockNow)

        XCTAssertEqual(workerIndex, 2, "restart must create a fresh worker instance")
        XCTAssertTrue(workers[0].stopped, "old instance must be stopped, not reused")
        XCTAssertFalse(workers[1].stopped)
        XCTAssertTrue(workers[0] !== workers[1])
    }

    // MARK: - 3. Target-mismatch restart

    func test_targetMismatchTriggersRestartOntoNewDevice() {
        var currentDevices: [AudioDeviceID] = [1]
        let sup = makeSupervisor(
            snapshot: { [self] in [processInfo("com.app.a", devices: currentDevices)] },
            restartPolicy: .init(watchdogThreshold: 4, baseDelay: 0, maxDelay: 30)
        )

        let status1 = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertTrue(status1.isCapturing)
        XCTAssertEqual(workers[0].startTarget, .device(1))
        XCTAssertFalse(workers[0].stopped)

        currentDevices = [2]
        clockNow = clockNow.addingTimeInterval(1)
        let status2 = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertTrue(status2.isCapturing)
        XCTAssertTrue(workers[0].stopped, "old worker should be stopped on device switch")
        XCTAssertEqual(workers[1].startTarget, .device(2))
    }

    // MARK: - 4. Watchdog restart on stalled bytes

    func test_watchdogRestartsOnStalledByteFlow() {
        let sup = makeSupervisor(restartPolicy: .init(watchdogThreshold: 4, baseDelay: 0, maxDelay: 30))

        let status1 = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertTrue(status1.isCapturing)
        XCTAssertFalse(workers[0].stopped)

        // No chunks delivered — advance past watchdogThreshold.
        clockNow = clockNow.addingTimeInterval(5)
        let status2 = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertTrue(status2.isCapturing)
        XCTAssertTrue(workers[0].stopped, "stalled worker should be restarted")
        XCTAssertEqual(workerIndex, 2)
    }

    // MARK: - 5. Silence ladder end-to-end

    func test_silenceLadderReResolvesThenRetriesThenHolds() {
        let sup = makeSupervisor(
            restartPolicy: .init(watchdogThreshold: 100, baseDelay: 0, maxDelay: 30),
            silencePolicy: .init(silenceThreshold: 10, maxSilentRestarts: 2)
        )

        let status1 = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertTrue(status1.isCapturing)
        workers[0].deliverSilence()

        // Step 1: reResolveAndRestart after silenceThreshold elapses.
        clockNow = clockNow.addingTimeInterval(11)
        let status2 = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertTrue(status2.isCapturing)
        XCTAssertTrue(workers[0].stopped, "first silence restart should replace worker")
        XCTAssertEqual(status2.health, .recovering)
        workers[1].deliverSilence()

        // Step 2: SilenceRecoveryPolicy's .reResolving state issues reResolveAndRestart
        // again (same action, second time); noteRestart then advances armed→reResolving→
        // retrying since the resolved target is unchanged both times.
        clockNow = clockNow.addingTimeInterval(11)
        let status3 = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertTrue(status3.isCapturing)
        XCTAssertTrue(workers[1].stopped, "second silence restart should replace worker again")
        workers[2].deliverSilence()

        // Step 3: ladder exhausted -> hold, capturing continues, no further restart.
        clockNow = clockNow.addingTimeInterval(11)
        let status4 = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertTrue(status4.isCapturing)
        XCTAssertEqual(status4.health, .holdingSilent)
        XCTAssertFalse(workers[2].stopped, "holding worker should keep running, not be restarted")
    }

    // MARK: - 6. Backoff suppression of signals

    func test_backoffSuppressesEnvironmentSignal() {
        let sup = makeSupervisor(restartPolicy: .init(watchdogThreshold: 100, baseDelay: 30, maxDelay: 30))
        sup.start() // wires signals.handler — required for signals.send() to reach the supervisor

        _ = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertFalse(workers[0].stopped)

        // Immediately (well within baseDelay) send a disturbance signal.
        signals.send(.captureDisturbed("format changed"))
        clockNow = clockNow.addingTimeInterval(1)
        let status = sup.apply(demand: [demand("com.app.a")], now: clockNow)

        XCTAssertFalse(workers[0].stopped, "restart should be suppressed by backoff")
        XCTAssertTrue(status.isCapturing)
        XCTAssertEqual(workerIndex, 1, "no new worker should have been created")
    }

    // MARK: - 7. defaultInputChanged ignored while pinned

    func test_defaultInputChangedIgnoredWhenTargetIsPinnedDevice() {
        let sup = makeSupervisor(
            snapshot: { [self] in [processInfo("com.app.a", devices: [7])] },
            restartPolicy: .init(watchdogThreshold: 100, baseDelay: 0, maxDelay: 30)
        )
        sup.start()

        _ = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertEqual(workers[0].startTarget, .device(7))

        signals.send(.defaultInputChanged)
        clockNow = clockNow.addingTimeInterval(1)
        let status = sup.apply(demand: [demand("com.app.a")], now: clockNow)

        XCTAssertFalse(workers[0].stopped, "defaultInputChanged must not restart a pinned-device capture")
        XCTAssertTrue(status.isCapturing)
        XCTAssertEqual(workerIndex, 1)
    }

    func test_defaultInputChangedRestartsWhenTargetIsSystemDefault() {
        let sup = makeSupervisor(restartPolicy: .init(watchdogThreshold: 100, baseDelay: 0, maxDelay: 30))
        sup.start()

        _ = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertEqual(workers[0].startTarget, .systemDefault)

        signals.send(.defaultInputChanged)
        clockNow = clockNow.addingTimeInterval(1)
        let status = sup.apply(demand: [demand("com.app.a")], now: clockNow)

        XCTAssertTrue(workers[0].stopped, "defaultInputChanged should restart a systemDefault-targeted capture")
        XCTAssertTrue(status.isCapturing)
        XCTAssertEqual(workerIndex, 2)
    }

    // MARK: - 8. Error escalation at 3

    func test_errorLoggedAtThirdConsecutiveUnhealthyRestart() {
        // Each start throws, forcing wasFlowing=false every attempt; baseDelay=0 keeps
        // mayRestart permissive so we can drive attempts back-to-back. Every failed
        // attempt independently logs "worker start failed" — that's expected noise,
        // not the signal under test — so we filter for the specific escalation message.
        //
        // CaptureRestartPolicy.recordRestart treats the FIRST-EVER attempt as neutral
        // (no prior lastRestartAt to compare against), so consecutiveUnhealthyRestarts
        // only starts counting from the 2nd attempt: 0, 0, 1, 2, 3 after attempts
        // 1..5. The escalation log (>= 3) therefore fires starting on the 4th attempt.
        for w in workers { w.startError = .deviceUnavailable(1) }
        let sup = makeSupervisor(restartPolicy: .init(watchdogThreshold: 100, baseDelay: 0, maxDelay: 30))

        func escalations() -> [String] {
            diagnostics.errors.filter { $0.contains("3+ consecutive unhealthy restarts") }
        }

        for i in 0..<3 {
            let status = sup.apply(demand: [demand("com.app.a")], now: clockNow)
            XCTAssertFalse(status.isCapturing)
            XCTAssertTrue(escalations().isEmpty, "no escalation expected before the 4th attempt (i=\(i))")
            clockNow = clockNow.addingTimeInterval(1)
        }

        let status4 = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertFalse(status4.isCapturing)
        XCTAssertEqual(workerIndex, 4)
        XCTAssertEqual(escalations().count, 1, "exactly one escalation log after the 4th consecutive unhealthy attempt")
    }

    // MARK: - 9. Status/health reporting

    func test_healthReportsIdleCapturingRecoveringHoldingSilent() {
        // Idle + capturing: fresh, isolated supervisor.
        let sup = makeSupervisor(restartPolicy: .init(watchdogThreshold: 100, baseDelay: 0, maxDelay: 30))

        let idle = sup.apply(demand: [], now: clockNow)
        XCTAssertEqual(idle.health, .idle)

        let capturing = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertEqual(capturing.health, .capturing)
        XCTAssertFalse(capturing.health == .recovering, "a plain arrival start is healthy, not recovering")

        // Recovering: stall on the next tick, isolated supervisor + very small watchdog.
        let sup2 = makeSupervisor(restartPolicy: .init(watchdogThreshold: 1, baseDelay: 0, maxDelay: 30))
        _ = sup2.apply(demand: [demand("com.app.b")], now: clockNow)
        clockNow = clockNow.addingTimeInterval(2)
        let recovering = sup2.apply(demand: [demand("com.app.b")], now: clockNow)
        XCTAssertEqual(recovering.health, .recovering)

        // Holding: drive the silence ladder to exhaustion, isolated supervisor.
        let sup3 = makeSupervisor(
            restartPolicy: .init(watchdogThreshold: 100, baseDelay: 0, maxDelay: 30),
            silencePolicy: .init(silenceThreshold: 10, maxSilentRestarts: 1)
        )
        clockNow = clockNow.addingTimeInterval(1)
        _ = sup3.apply(demand: [demand("com.app.c")], now: clockNow)
        let holdWorker1 = workers[workerIndex - 1]
        holdWorker1.deliverSilence()

        clockNow = clockNow.addingTimeInterval(11)
        let step1 = sup3.apply(demand: [demand("com.app.c")], now: clockNow) // ladder step 1 (restart)
        XCTAssertEqual(step1.health, .recovering)
        let holdWorker2 = workers[workerIndex - 1]
        XCTAssertTrue(holdWorker1 !== holdWorker2, "ladder step should have created a fresh worker")
        holdWorker2.deliverSilence()

        clockNow = clockNow.addingTimeInterval(11)
        let step2 = sup3.apply(demand: [demand("com.app.c")], now: clockNow) // ladder step 2 (restart)
        XCTAssertEqual(step2.health, .recovering)
        let holdWorker3 = workers[workerIndex - 1]
        XCTAssertTrue(holdWorker2 !== holdWorker3, "second ladder step should also create a fresh worker")
        holdWorker3.deliverSilence()

        clockNow = clockNow.addingTimeInterval(11)
        let holding = sup3.apply(demand: [demand("com.app.c")], now: clockNow) // holdEntered
        XCTAssertEqual(holding.health, .holdingSilent)
        XCTAssertFalse(holdWorker3.stopped, "holding must keep the current worker running, not restart it")
    }

    // MARK: - 10. Demand-empty abandons worker and resets policies

    func test_emptyDemandAbandonsWorkerAndResetsPolicies() {
        let sup = makeSupervisor(restartPolicy: .init(watchdogThreshold: 4, baseDelay: 5, maxDelay: 30))

        _ = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertFalse(workers[0].stopped)

        clockNow = clockNow.addingTimeInterval(1)
        let stopped = sup.apply(demand: [], now: clockNow)
        XCTAssertFalse(stopped.isCapturing)
        XCTAssertEqual(stopped.health, .idle)
        XCTAssertTrue(workers[0].stopped)

        // Restart policy was reset (no backoff lingering) — a new demand immediately
        // after should be allowed to start right away despite baseDelay=5.
        clockNow = clockNow.addingTimeInterval(0.1)
        let restarted = sup.apply(demand: [demand("com.app.a")], now: clockNow)
        XCTAssertTrue(restarted.isCapturing, "restart policy should have been reset on empty demand")
        XCTAssertEqual(workerIndex, 2)
    }
}
