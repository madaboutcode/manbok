import CoreAudio
import XCTest
import ManbokCore
@testable import ManbokPlatform

// MARK: - CONTRACT: ReducerModelReplayTests
//
// Replays traces of Tests/verify/reducer/session.model.mjs against the real DemandReducer, driven
// through the real SessionLifecycleController tick (snapshot filter, reducer, supervisor apply, recheck
// step, session ops). Each mutant counterexample of the model that maps to real code is one test, named
// after the model rule it protects and the variant it kills (see Tests/verify/reducer/README.md). The
// step comments are the model's action names, in the model's order.
//
// The supervisor here is the model's supervisor without the restart budget: it captures iff some demand
// entry lists a device, keeps its device while that device is still a candidate, else takes the lowest.
// The 4 s restart-budget question is asked of the real CaptureSupervisor in the last test.

private final class ModelSupervisor: CaptureSupervising {
    private(set) var device: UInt32?
    private(set) var lastDemand: [DemandEntry] = []
    /// Model event "capture start fails": the next this-many start attempts fail (device stays nil).
    var failingStarts = 0

    func apply(demand: [DemandEntry], now: Date) -> CaptureStatus {
        lastDemand = demand
        let candidates = demand.reduce(into: Set<UInt32>()) { $0.formUnion($1.deviceIDs) }
        if let d = device, candidates.contains(d) {
            // keep
        } else if let target = candidates.min() {
            if failingStarts > 0 {
                failingStarts -= 1
                device = nil
            } else {
                device = target
            }
        } else {
            device = nil
        }
        return CaptureStatus(isCapturing: device != nil, health: device != nil ? .capturing : .deferredNoDevice)
    }
}

/// The model's world: apps recording on mics, mics that exist, a 1 s event grid, polls every second tick of 2.
private final class ModelWorld {
    let supervisor = ModelSupervisor()
    let registry = SessionRegistry(ringCapacity: BufferPolicy.capacityBytes(for: .min5))
    private(set) var controller: SessionLifecycleController!
    private var recordingOn: [Int: UInt32] = [:]
    private var blipped: Set<Int> = []
    private var mics: Set<UInt32>
    private var clock: TimeInterval = 100
    private var excludedGroups: Set<String> = []

    static func id(_ app: Int) -> String { "com.replay.app\(app)" }

    init(mics: Set<UInt32> = [1, 2]) {
        self.mics = mics
        controller = SessionLifecycleController(
            supervisor: supervisor,
            registry: registry,
            holderSnapshot: { [unowned self] in snapshot() },
            resolver: .shared,
            permission: { .authorized },
            pollInterval: 2,
            gracePeriod: 5,
            monotonicNow: { [unowned self] in clock }
        )
    }

    private func snapshot() -> HolderSnapshot {
        let holders = recordingOn.keys.sorted().compactMap { app -> HolderObservation? in
            guard !blipped.contains(app), let mic = recordingOn[app], mics.contains(mic) else { return nil }
            return HolderObservation(appID: Self.id(app), pid: Int32(app), inputDevices: [mic])
        }
        return HolderSnapshot(holders: holders, liveInputDevices: mics)
    }

    // Model actions
    func startsRecording(_ app: Int, onMic mic: UInt32) { recordingOn[app] = mic }
    func stopsInput(_ app: Int) { recordingOn[app] = nil }
    func losesMicFromListForOnePoll(_ app: Int) { blipped.insert(app) }
    func micDisappears(_ mic: UInt32) {
        mics.remove(mic)
        recordingOn = recordingOn.filter { $0.value != mic }
    }
    func micComesBack(_ mic: UInt32) { mics.insert(mic) }
    func oneSecondPasses() { clock += 1 }

    /// "poll tick": one controller tick at the current model time; a list blip lasts one poll.
    func pollTick() {
        controller.pollOnce()
        blipped.removeAll()
    }

    /// "you exclude/un-exclude app": the controller polls at once (a settings change), outside the 2 s cadence.
    func setExcluded(_ app: Int, _ excluded: Bool) {
        if excluded { excludedGroups.insert(appGroup(Self.id(app))) } else { excludedGroups.remove(appGroup(Self.id(app))) }
        controller.setExcludedGroups(excludedGroups)
        _ = controller.reducerOpenSessions   // barrier: setExcludedGroups has run on the controller's queue
        pollTick()                           // the controller is not started here, so setExcludedGroups does not poll; this is that immediate poll
    }

    /// Two 1 s steps and the poll tick: the model's regular cadence.
    func regularPoll() {
        oneSecondPasses()
        oneSecondPasses()
        pollTick()
    }

    // Observations
    var openSessions: Set<String> { controller.reducerOpenSessions }
    var capturing: Bool { supervisor.device != nil }
    var demandedApps: Set<String> { Set(supervisor.lastDemand.map(\.bundleID)) }
    func candidates(of app: Int) -> Set<UInt32> {
        supervisor.lastDemand.first { $0.bundleID == Self.id(app) }?.deviceIDs ?? []
    }
}

final class ReducerModelReplayTests: XCTestCase {
    private let app1 = ModelWorld.id(1)
    private let app2 = ModelWorld.id(2)

    // MARK: - Normal path through the mirrored actions (model fix variant)

    func test_normalPath_holdDrainReclaimExpire() {
        let w = ModelWorld()
        w.startsRecording(1, onMic: 1)                                  // app 1 starts recording on mic 1
        w.regularPoll()                                                 // poll tick
        XCTAssertEqual(w.openSessions, [app1])                          // session opens in the same tick capture comes up
        XCTAssertTrue(w.capturing)
        w.stopsInput(1)                                                 // app 1 stops its input
        w.regularPoll()                                                 // draining (deadline +5 s), session and capture stay
        XCTAssertEqual(w.openSessions, [app1])
        XCTAssertTrue(w.capturing)
        w.startsRecording(1, onMic: 1)                                  // returns inside the grace: same session
        w.regularPoll()
        XCTAssertEqual(w.openSessions, [app1])
        w.stopsInput(1)
        w.regularPoll()                                                 // t: drain starts, deadline t+5
        w.regularPoll()                                                 // t+2
        w.regularPoll()                                                 // t+4: still inside the grace
        XCTAssertEqual(w.openSessions, [app1])
        w.regularPoll()                                                 // t+6 >= deadline t+5
        XCTAssertEqual(w.openSessions, [])
        XCTAssertFalse(w.capturing)
    }

    // MARK: - P4, variant rowsess: a draining app without a session gets one when capture comes up

    func test_P4_holderListedBlipWhileCaptureWasDown_getsSessionWhenCaptureComesUp() {
        let w = ModelWorld()
        w.supervisor.failingStarts = 1                                  // capture-start failure
        w.startsRecording(1, onMic: 1)                                  // app 1 starts recording on mic 1
        w.regularPoll()                                                 // poll tick: start fails, no session yet
        XCTAssertFalse(w.capturing)
        XCTAssertEqual(w.openSessions, [])
        w.losesMicFromListForOnePoll(1)                                 // app 1 loses its mic from the device list for one poll
        w.regularPoll()                                                 // draining app 1, kept mic 1 still exists: capture starts
        XCTAssertTrue(w.capturing)
        XCTAssertEqual(w.openSessions, [app1], "app 1 really holds the mic and capture runs: it must have a session after this poll")
    }

    // MARK: - P5, variant p5union: a draining app's device does not compete with a holder's

    func test_P5_drainingAppDeviceNeverChosenWhileAHolderListsADevice() {
        let w = ModelWorld()
        w.startsRecording(2, onMic: 2)                                  // app 2 starts recording on mic 2
        w.regularPoll()                                                 // capture on mic 2
        w.startsRecording(1, onMic: 1)                                  // app 1 starts recording on mic 1
        w.regularPoll()
        w.stopsInput(2)                                                 // app 2 stops: draining, kept mic 2
        w.regularPoll()
        XCTAssertEqual(w.candidates(of: 2), [], "draining app 2 offers no device while app 1 holds mic 1")
        XCTAssertEqual(w.supervisor.device, 1, "capture follows the holder, not the draining app's mic")
    }

    // MARK: - P5, variant stale: a vanished device is never a candidate; the session survives (design 4b)

    func test_P5_vanishedKeptDeviceDroppedSessionStaysOpen() {
        let w = ModelWorld()
        w.startsRecording(1, onMic: 1)
        w.regularPoll()
        w.micDisappears(1)                                              // mic 1 disappears (apps on it stop recording)
        w.regularPoll()
        XCTAssertEqual(w.candidates(of: 1), [])
        XCTAssertFalse(w.capturing, "no known device: capture is off, not parked on a vanished mic")
        XCTAssertEqual(w.openSessions, [app1], "the session stays open through the no-device poll")
    }

    // MARK: - P1, variant nofallback: a draining app's kept device keeps capture up through a list blip

    func test_P1_listBlipKeepsCaptureOnKeptDevice() {
        let w = ModelWorld()
        w.startsRecording(1, onMic: 1)
        w.regularPoll()
        w.losesMicFromListForOnePoll(1)
        w.regularPoll()
        XCTAssertTrue(w.capturing, "the kept mic still exists: capture must not drop for one poll")
        XCTAssertEqual(w.openSessions, [app1])
    }

    // MARK: - P4, variant nostep2: the session opens in the tick capture comes up

    func test_P4_sessionOpensInTheSameTickCaptureComesUp() {
        let w = ModelWorld()
        w.startsRecording(1, onMic: 1)
        w.regularPoll()
        XCTAssertEqual(w.openSessions, [app1])
        XCTAssertEqual(w.registry.anySessionOpen, true)
    }

    // MARK: - Excl, variants excl-ignore and excl-late: excluding an app ends its session and its capture

    func test_Excl_excludedAppSessionAndCaptureEndWithinBound() {
        let w = ModelWorld()
        w.startsRecording(1, onMic: 1)
        w.regularPoll()
        XCTAssertEqual(w.openSessions, [app1])
        w.setExcluded(1, true)                                          // you exclude app 1: immediate poll, drain starts
        w.regularPoll()                                                 // +2
        w.regularPoll()                                                 // +4
        w.regularPoll()                                                 // +6 >= deadline: closed, inside the model's 8 s bound
        XCTAssertEqual(w.openSessions, [])
        XCTAssertFalse(w.capturing)
    }

    func test_Excl_excludedBeforeArrival_neverGetsSessionOrDemand() {
        let w = ModelWorld()
        w.setExcluded(1, true)
        w.startsRecording(1, onMic: 1)
        w.regularPoll()
        XCTAssertEqual(w.openSessions, [])
        XCTAssertEqual(w.demandedApps, [])
        XCTAssertFalse(w.capturing)
    }

    // MARK: - ExclNew (model finding, expected to break): an excluded draining app gets a session when capture comes up

    /// Model path (run-findings-excl-C.txt): app 1 starts, its capture start fails, you exclude app 1, capture then
    /// comes up for another app. The reducer's session rule covers every non-absent app, so excluded app 1 (draining)
    /// is given a session. The desired rule is "no new session for an excluded app". XCTExpectFailure keeps the
    /// suite green while the finding stands and turns red ("unexpected pass") when the rule is fixed.
    func test_ExclNew_excludedDrainingAppWithoutSession_shouldNotGetSessionWhenCaptureComesUp() {
        let w = ModelWorld()
        w.supervisor.failingStarts = 1
        w.startsRecording(1, onMic: 1)
        w.regularPoll()                                                 // start fails: no session for app 1
        w.setExcluded(1, true)                                          // draining, no session
        w.startsRecording(2, onMic: 2)
        w.regularPoll()                                                 // capture comes up for app 2
        XCTAssertTrue(w.capturing)
        XCTAssertTrue(w.openSessions.contains(app2))
        XCTExpectFailure("finding: DemandReducer opens a session for a draining app that the user excluded") {
            XCTAssertFalse(w.openSessions.contains(app1), "excluded app 1 must not get a new session")
        }
    }
}

// MARK: - Restart budget after a mic switch through "no device" (model rules A3 and Slow)

private final class BudgetWorker: PinnedAudioCapturing {
    private var sink: ((CaptureChunk) -> Void)?
    private(set) var boundDevice: AudioDeviceID?
    func start(target: CaptureTarget, sink: @escaping (CaptureChunk) -> Void) throws {
        self.sink = sink
        if case .device(let id) = target { boundDevice = id }
    }
    func stop() { sink = nil }
    func deliverChunk() { sink?(CaptureChunk(pcm: Data(count: 32000), peak: 1000)) }
}

private final class BudgetSignals: EnvironmentSignaling {
    var handler: ((EnvironmentSignal) -> Void)?
    func activate() {}
    func deactivate() {}
    func observe(device: AudioDeviceID?) {}
}

/// The reducer model cannot decide the restart budget: that is CaptureSupervisor + CaptureRestartPolicy. This replays the
/// model's switch (run-findings-*.txt, rule Slow) on the real supervisor: start on mic 1 with audio flowing, release
/// because no device is known, start on mic 2 after `gap` seconds, release again, ask for mic 3 once the base delay
/// (3 s) has passed since the start on mic 2. Mic 3 starts iff start #2 did not count as an unhealthy restart.
final class ReducerModelBudgetReplayTests: XCTestCase {
    private func mic3Starts(gapAfterLastByte gap: TimeInterval) -> Bool {
        var now = Date(timeIntervalSince1970: 1000)
        var workers: [BudgetWorker] = []
        let sup = CaptureSupervisor(
            makeWorker: { let w = BudgetWorker(); workers.append(w); return w },
            signals: BudgetSignals(),
            appendSink: { _ in },
            restartPolicy: .init(watchdogThreshold: 4, baseDelay: 3, maxDelay: 100),
            silencePolicy: .init(silenceThreshold: 100, maxSilentRestarts: 2),
            clock: { now }
        )
        func entry(_ devices: Set<UInt32>) -> DemandEntry { DemandEntry(bundleID: "com.replay.app1", pid: 1, arrivedAt: now, deviceIDs: devices) }
        _ = sup.apply(demand: [entry([1])], now: now)               // start #1 (first attempt: neutral)
        workers[0].deliverChunk()                                   // last audio byte at t0
        let lastByte = now
        now = lastByte.addingTimeInterval(gap > 1 ? 1 : gap)
        _ = sup.apply(demand: [entry([])], now: now)                // released: no candidate device
        now = lastByte.addingTimeInterval(gap)
        XCTAssertTrue(sup.apply(demand: [entry([2])], now: now).isCapturing, "start #2 on mic 2")
        now = now.addingTimeInterval(0.5)
        _ = sup.apply(demand: [entry([])], now: now)                // released again (the new worker produced nothing yet)
        now = now.addingTimeInterval(2.5)                           // 3.0 s after start #2 = baseDelay
        return sup.apply(demand: [entry([3])], now: now).isCapturing
    }

    func test_A3_switchRestartedWithin4sOfLastByte_doesNotGrowBackoff() {
        XCTAssertTrue(mic3Starts(gapAfterLastByte: 3), "audio 3 s old at start #2: healthy switch, delay stays 3 s")
    }

    func test_Slow_finding_switchRestartedAfter4sOfLastByte_growsBackoff() {
        XCTAssertFalse(mic3Starts(gapAfterLastByte: 5),
                       "audio 5 s old at start #2 (>= watchdogThreshold): counted unhealthy, delay doubles to 6 s, mic 3 is deferred")
    }
}
