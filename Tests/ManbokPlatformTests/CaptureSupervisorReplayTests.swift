import CoreAudio
import XCTest
@testable import ManbokPlatform

// Replays the scenarios of Tests/verify/supervisor/replay.mjs against the real CaptureSupervisor.
// The expected rows come from the hand-mirrored order model (CaptureSupervisorReplayExpected.swift,
// generated). A row is read after every poll: capturing, resolved target, start attempts so far,
// health == holdingSilent, health == deferredNoDevice.
//
// N* = one normal path through each mirrored action. B* = break paths found by the model on the
// current code (B1: backoff after slow mic switches, B2: stale hold flag, B3: stale backoff after a long run).
// M* = the counterexample of a mutant model; each fails when the matching fix is removed
// (README.md of Tests/verify/supervisor, table "mutant -> rule -> replay").

private final class ReplayWorker: PinnedAudioCapturing {
    private(set) var target: CaptureTarget?
    private(set) var boundDevice: AudioDeviceID?
    private var sink: ((CaptureChunk) -> Void)?
    let failStart: Bool

    init(failStart: Bool) { self.failStart = failStart }

    func start(target: CaptureTarget, sink: @escaping (CaptureChunk) -> Void) throws {
        if failStart { throw PinnedCaptureError.deviceUnavailable(1) }
        self.target = target
        self.sink = sink
        if case .device(let id) = target { boundDevice = id }
    }

    func stop() { sink = nil }

    func deliver(peak: Int16) { sink?(CaptureChunk(pcm: Data(count: 32000), peak: peak)) }
    var isRunning: Bool { sink != nil }
}

private final class ReplayEnvironment: EnvironmentSignaling {
    var handler: ((EnvironmentSignal) -> Void)?
    func activate() {}
    func deactivate() { handler = nil }
    func observe(device: AudioDeviceID?) {}
}

private final class SilentDiagnostics: DiagnosticsWriting, @unchecked Sendable {
    func notice(category: AppLog.Category, _ message: String) {}
    func info(category: AppLog.Category, _ message: String) {}
    func warning(category: AppLog.Category, _ message: String) {}
    func error(category: AppLog.Category, _ message: String) {}
    func debug(category: AppLog.Category, _ message: String) {}
}

/// Interprets the scenario tokens of replay.mjs: list:<app>:<mic> | empty | mode:F|S|N|FN | signal | poll | poll! | stop.
private final class SupervisorReplay {
    typealias Row = ReplayExpected.Row
    private static let poll: TimeInterval = 2
    private var clockNow = Date(timeIntervalSince1970: 1000)
    private let environment = ReplayEnvironment()
    private var made: [ReplayWorker] = []
    private var failStarts = false
    private var supervisor: CaptureSupervisor!
    private var demand: [DemandEntry] = []
    private var mode = "F"

    init() {
        supervisor = CaptureSupervisor(
            makeWorker: { [unowned self] in
                let worker = ReplayWorker(failStart: failStarts)
                made.append(worker)
                return worker
            },
            signals: environment,
            appendSink: { _ in },
            restartPolicy: .init(watchdogThreshold: 4, baseDelay: 1, maxDelay: 30),
            silencePolicy: .init(silenceThreshold: 10, maxSilentRestarts: 2),
            clock: { [unowned self] in clockNow }
        )
        supervisor.start()
    }

    func run(_ steps: [String]) -> [Row] {
        var rows: [Row] = []
        for step in steps {
            let parts = step.split(separator: ":").map(String.init)
            switch parts[0] {
            case "list":
                let mic = UInt32(parts[2])!
                demand = [DemandEntry(bundleID: "com.app.\(parts[1])", pid: 100, arrivedAt: Date(timeIntervalSince1970: 1000),
                                      deviceIDs: mic == 0 ? [] : [mic])]
            case "empty": demand = []
            case "mode": mode = parts[1]
            case "signal": environment.handler?(.captureDisturbed("replay"))
            case "poll", "poll!":
                failStarts = step == "poll!"
                rows.append(pollOnce())
                failStarts = false
            case "stop":
                supervisor.stop()
                rows.append((false, 0, made.count, false, false))
            default: preconditionFailure("unknown token \(step)")
            }
        }
        return rows
    }

    /// One 2 s interval: the running worker's chunks arrive (ages as in the model), then apply() runs.
    private func pollOnce() -> Row {
        let pollTime = clockNow.addingTimeInterval(Self.poll)
        if let worker = made.last, worker.isRunning {
            func deliver(at offset: TimeInterval, peak: Int16) {
                clockNow = pollTime.addingTimeInterval(-offset)
                worker.deliver(peak: peak)
            }
            switch mode {
            case "F": deliver(at: 0.1, peak: 1000)
            case "S": deliver(at: 1.9, peak: 0); deliver(at: 0.1, peak: 0)
            case "FN": deliver(at: 1.0, peak: 1000); mode = "N"
            default: break
            }
        }
        clockNow = pollTime
        let status = supervisor.apply(demand: demand, now: clockNow)
        let target: UInt32 = {
            guard status.isCapturing, case .device(let id)? = made.last?.target else { return 0 }
            return id
        }()
        return (status.isCapturing, target, made.count, status.health == .holdingSilent, status.health == .deferredNoDevice)
    }
}

final class CaptureSupervisorReplayTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Diagnostics.install(SilentDiagnostics())
    }

    override func tearDown() {
        Diagnostics.install(OSLogAndStderrDiagnostics())
        super.tearDown()
    }

    private func assertReplay(_ name: String, _ steps: [String], _ expected: [ReplayExpected.Row],
                              file: StaticString = #filePath, line: UInt = #line) {
        let actual = SupervisorReplay().run(steps)
        XCTAssertEqual(actual.count, expected.count, "\(name): number of observed rows", file: file, line: line)
        for (i, (a, e)) in zip(actual, expected).enumerated() {
            XCTAssertTrue(a == e,
                          "\(name) row \(i + 1): real (capturing, target, attempts, holding, deferred) = \(a), model = \(e)",
                          file: file, line: line)
        }
    }

    // MARK: normal paths, one per mirrored action

    func test_N1_arrivalStartsWorker() { assertReplay("N1", ReplayExpected.N1_arrival_steps, ReplayExpected.N1_arrival) }
    func test_N2_emptyDemandAbandonsAndResets() { assertReplay("N2", ReplayExpected.N2_emptyDemandAbandon_steps, ReplayExpected.N2_emptyDemandAbandon) }
    func test_N3_healthyDeviceSwitch() { assertReplay("N3", ReplayExpected.N3_deviceSwitchHealthy_steps, ReplayExpected.N3_deviceSwitchHealthy) }
    func test_N4_stallWatchdogRestartsDeadWorker() { assertReplay("N4", ReplayExpected.N4_stallWatchdog_steps, ReplayExpected.N4_stallWatchdog) }
    func test_N5_silenceLadderThenHold() { assertReplay("N5", ReplayExpected.N5_silenceLadder_steps, ReplayExpected.N5_silenceLadder) }
    func test_N6_captureDisturbedRestarts() { assertReplay("N6", ReplayExpected.N6_signalRestart_steps, ReplayExpected.N6_signalRestart) }
    func test_N7_releaseThenStart() { assertReplay("N7", ReplayExpected.N7_releaseThenStart_steps, ReplayExpected.N7_releaseThenStart) }
    func test_N8_startFailuresBackOff() { assertReplay("N8", ReplayExpected.N8_startFailureBackoff_steps, ReplayExpected.N8_startFailureBackoff) }
    func test_N9_stopReleasesWorker() { assertReplay("N9", ReplayExpected.N9_stop_steps, ReplayExpected.N9_stop) }

    // MARK: break paths on the current code (model findings; the expected rows describe today's behaviour)

    /// Four mic switches that each take more than 4 s from the last byte: the fifth capture start waits two extra polls.
    func test_B1_slowMicSwitchesGrowBackoffAndDeferFifthStart() { assertReplay("B1", ReplayExpected.B1_fourSlowSwitchesDeferFifth_steps, ReplayExpected.B1_fourSlowSwitchesDeferFifth) }
    /// A failed start after the silence ladder gave up leaves health at holdingSilent with no worker (rule R5_holdHealth).
    func test_B2_failedStartAfterHoldKeepsHoldingSilentHealth() { assertReplay("B2", ReplayExpected.B2_holdThenStartFailure_steps, ReplayExpected.B2_holdThenStartFailure) }
    func test_B3_backoffCountSurvivesLongHealthyRun() { assertReplay("B3", ReplayExpected.B3_staleBackoffAfterLongFlow_steps, ReplayExpected.B3_staleBackoffAfterLongFlow) }

    // MARK: mutant counterexamples (fail when the matching fix is removed from production code)

    /// A3: a release for "no candidate device" keeps lastDataAt. Fix removed (clear on release): fast switches grow the backoff.
    func test_M1_fastMicSwitchesDoNotGrowBackoff() { assertReplay("M1", ReplayExpected.M1_fastSwitchesKeepBackoffLow_steps, ReplayExpected.M1_fastSwitchesKeepBackoffLow) }
    /// CaptureRestartPolicy.recordRestart resets the count on a restart of a flowing worker.
    func test_M2_liveSwitchesResetBackoff() { assertReplay("M2", ReplayExpected.M2_liveSwitchesResetBackoff_steps, ReplayExpected.M2_liveSwitchesResetBackoff) }
    /// CaptureRestartPolicy.isStalled counts the capture start as evidence.
    func test_M3_freshWorkerGetsGraceBeforeStall() { assertReplay("M3", ReplayExpected.M3_freshWorkerGetsGraceBeforeStall_steps, ReplayExpected.M3_freshWorkerGetsGraceBeforeStall) }
    /// SilenceRecoveryPolicy.noteRestart: armed goes to re-resolving, not straight to retrying.
    func test_M4_silenceLadderStepsBeforeHold() { assertReplay("M4", ReplayExpected.M4_silenceLadderStepsBeforeHold_steps, ReplayExpected.M4_silenceLadderStepsBeforeHold) }
    func test_M5_emptyDemandReleasesWorkerAndReturnStartsFresh() { assertReplay("M5", ReplayExpected.M5_emptyDemandThenQuickReturn_steps, ReplayExpected.M5_emptyDemandThenQuickReturn) }
    /// GUARANTEES: no candidate device releases the worker (no gap hold).
    func test_M6_noCandidateDeviceReleasesWorker() { assertReplay("M6", ReplayExpected.M6_noDeviceReleasesWorker_steps, ReplayExpected.M6_noDeviceReleasesWorker) }
    /// CaptureRestartPolicy.currentDelay is capped at maxDelay.
    func test_M7_restartDelayIsCapped() { assertReplay("M7", ReplayExpected.M7_delayIsCapped_steps, ReplayExpected.M7_delayIsCapped) }
}
