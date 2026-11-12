import XCTest
import ManbokCore
@testable import ManbokPlatform

// MARK: - CONTRACT: SessionLifecycleControllerTests
//
// Exercises SessionLifecycleController against a fake CaptureSupervising (the waist) and a
// fake holder snapshot, using the real SessionRegistry (Core, hardware-free). Poll interval
// and grace period are shortened for the test run; assertions poll the *current* run loop
// (RunLoop.current.run(until:)) rather than Thread.sleep, so DispatchQueue.main.async
// publishes from the controller's background queue are actually drained on the main thread
// before each check — a bare Thread.sleep loop would leave those blocks queued and unrun.

private final class FakeSupervisor: CaptureSupervising {
    private let lock = NSLock()
    private var _lastDemand: [DemandEntry] = []
    private var _applyCount = 0
    private var _statusToReturn = CaptureStatus(isCapturing: true, health: .capturing)

    var lastDemand: [DemandEntry] {
        lock.lock(); defer { lock.unlock() }
        return _lastDemand
    }

    var applyCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _applyCount
    }

    var statusToReturn: CaptureStatus {
        get { lock.lock(); defer { lock.unlock() }; return _statusToReturn }
        set { lock.lock(); defer { lock.unlock() }; _statusToReturn = newValue }
    }

    func apply(demand: [DemandEntry], now: Date) -> CaptureStatus {
        lock.lock()
        _lastDemand = demand
        _applyCount += 1
        let status = _statusToReturn
        lock.unlock()
        return status
    }
}

private final class FakeProcessSource {
    private let lock = NSLock()
    private var _processes: [HolderObservation] = []

    var processes: [HolderObservation] {
        get { lock.lock(); defer { lock.unlock() }; return _processes }
        set { lock.lock(); defer { lock.unlock() }; _processes = newValue }
    }

    func snapshot() -> HolderSnapshot { HolderSnapshot(holders: processes, liveInputDevices: [1, 2]) }
}

final class SessionLifecycleControllerTests: XCTestCase {
    private let pollInterval: TimeInterval = 0.1
    private let gracePeriod: TimeInterval = 0.3

    private let testApp = HolderObservation(appID: "com.test.app", pid: 4242, inputDevices: [1])

    private func makeRegistry() -> SessionRegistry {
        SessionRegistry(ringCapacity: BufferPolicy.capacityBytes(for: .min5))
    }

    private func makeController(
        supervisor: CaptureSupervising,
        registry: SessionRegistry,
        processSource: FakeProcessSource
    ) -> SessionLifecycleController {
        SessionLifecycleController(
            supervisor: supervisor,
            registry: registry,
            holderSnapshot: processSource.snapshot,
            resolver: .shared,
            permission: { .authorized },
            pollInterval: pollInterval,
            gracePeriod: gracePeriod
        )
    }

    // Pumps the current run loop so both timer ticks (on the controller's background queue)
    // and any DispatchQueue.main.async publishes they trigger get a chance to run.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }

    private func pump(_ duration: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
    }

    // MARK: - 1. Set-diff open/close

    func test_setDiff_appArrivalOpensSession_departureAndDrainExpiryClosesIt() {
        let registry = makeRegistry()
        let supervisor = FakeSupervisor()
        let processSource = FakeProcessSource()
        let controller = makeController(supervisor: supervisor, registry: registry, processSource: processSource)

        controller.start()
        defer { controller.stop() }

        processSource.processes = [testApp]
        waitUntil { registry.anySessionOpen }

        processSource.processes = []
        waitUntil(timeout: 2.0) { !registry.anySessionOpen }
    }

    // MARK: - 2. Drain + cancel on reclaim

    func test_drain_reclaimBeforeExpiryCancelsTimer_sessionStaysOpenSameId() {
        let registry = makeRegistry()
        let supervisor = FakeSupervisor()
        let processSource = FakeProcessSource()
        let controller = makeController(supervisor: supervisor, registry: registry, processSource: processSource)

        controller.start()
        defer { controller.stop() }

        processSource.processes = [testApp]
        waitUntil { registry.anySessionOpen }
        // openSession is idempotent when a session is already open for this bundleID (see
        // SessionRegistry CONTRACT) — this reads the existing stable id without creating a
        // duplicate. listSessions() can't be used here: it filters out sessions with zero
        // surviving audio bytes, and this test never appends PCM (that's the supervisor's
        // job, out of scope for the lifecycle half).
        let stableIdBeforeDrain = registry.openSession(bundleID: testApp.appID, displayName: "unused")

        processSource.processes = []
        pump(gracePeriod * 0.5) // well inside the grace window — draining, not expired
        XCTAssertTrue(registry.anySessionOpen, "session must stay open while draining")

        processSource.processes = [testApp] // reclaim before drain expiry
        pump(gracePeriod * 2) // long past the ORIGINAL grace deadline

        XCTAssertTrue(registry.anySessionOpen, "reclaimed session must never have closed")
        XCTAssertEqual(
            registry.openSession(bundleID: testApp.appID, displayName: "unused"),
            stableIdBeforeDrain,
            "reclaim must resume the same session, not open a new one"
        )
    }

    // MARK: - 3. Arrivals deferred while not capturing

    func test_arrival_deferredWhileNotCapturing_admittedOnceCapturingBecomesTrue() {
        let registry = makeRegistry()
        let supervisor = FakeSupervisor()
        supervisor.statusToReturn = CaptureStatus(isCapturing: false, health: .idle)
        let processSource = FakeProcessSource()
        let controller = makeController(supervisor: supervisor, registry: registry, processSource: processSource)

        controller.start()
        defer { controller.stop() }

        processSource.processes = [testApp]
        pump(pollInterval * 5) // several ticks while the supervisor reports isCapturing == false
        XCTAssertFalse(registry.anySessionOpen, "arrival must defer while capture isn't up")

        supervisor.statusToReturn = CaptureStatus(isCapturing: true, health: .capturing)
        waitUntil { registry.anySessionOpen }
    }

    // MARK: - 4. One-signal rule

    func test_oneSignalRule_publishedAnySessionOpenStaysTrueThroughDrain() {
        let registry = makeRegistry()
        let supervisor = FakeSupervisor()
        let processSource = FakeProcessSource()
        let controller = makeController(supervisor: supervisor, registry: registry, processSource: processSource)

        controller.start()
        defer { controller.stop() }

        processSource.processes = [testApp]
        waitUntil { controller.anySessionOpen }

        processSource.processes = []
        pump(gracePeriod * 0.5) // draining — the registry may still show the session open too,
        XCTAssertTrue(controller.anySessionOpen, "published signal must stay true through drain")

        waitUntil(timeout: 2.0) { !controller.anySessionOpen } // drain expires -> signal drops
    }

    // MARK: - 5. Final empty apply on stop

    func test_stop_sendsFinalEmptyDemandApply() {
        let registry = makeRegistry()
        let supervisor = FakeSupervisor()
        let processSource = FakeProcessSource()
        let controller = makeController(supervisor: supervisor, registry: registry, processSource: processSource)

        controller.start()
        processSource.processes = [testApp]
        waitUntil { supervisor.applyCount > 0 && !supervisor.lastDemand.isEmpty }

        let countBeforeStop = supervisor.applyCount
        controller.stop()

        XCTAssertGreaterThan(supervisor.applyCount, countBeforeStop, "stop() must issue one more apply() call")
        XCTAssertTrue(supervisor.lastDemand.isEmpty, "the final apply on stop() must carry empty demand")
    }

    // MARK: - 6. arrivedAt stability

    func test_arrivedAt_preservedAcrossDepartAndReclaimWithinDrain() {
        let registry = makeRegistry()
        let supervisor = FakeSupervisor()
        let processSource = FakeProcessSource()
        let controller = makeController(supervisor: supervisor, registry: registry, processSource: processSource)

        controller.start()
        defer { controller.stop() }

        processSource.processes = [testApp]
        waitUntil { supervisor.lastDemand.contains { $0.bundleID == testApp.appID } }
        guard let firstArrivedAt = supervisor.lastDemand.first(where: { $0.bundleID == testApp.appID })?.arrivedAt else {
            return XCTFail("expected a demand entry for the test app")
        }

        processSource.processes = [] // depart
        pump(gracePeriod * 0.5) // inside grace — still draining

        processSource.processes = [testApp] // reclaim before drain expiry
        waitUntil { supervisor.lastDemand.contains { $0.bundleID == testApp.appID } }
        guard let reclaimedArrivedAt = supervisor.lastDemand.first(where: { $0.bundleID == testApp.appID })?.arrivedAt else {
            return XCTFail("expected a demand entry for the reclaimed test app")
        }

        XCTAssertEqual(
            firstArrivedAt,
            reclaimedArrivedAt,
            "arrivedAt must be preserved across a depart-and-reclaim inside the drain grace period"
        )
    }

    // MARK: - 7. Registry open set == reducer open set (ticks driven by hand, manual clock)

    func test_registryOpenSetEqualsReducerOpenSet_afterEveryTick() {
        let registry = makeRegistry()
        let supervisor = FakeSupervisor()
        let processSource = FakeProcessSource()
        var mono: TimeInterval = 100
        let controller = SessionLifecycleController(
            supervisor: supervisor,
            registry: registry,
            holderSnapshot: processSource.snapshot,
            permission: { .authorized },
            pollInterval: 2,
            gracePeriod: 5,
            monotonicNow: { mono }
        )
        let a = HolderObservation(appID: "com.test.a", pid: 1, inputDevices: [1])
        let b = HolderObservation(appID: "com.test.b", pid: 2, inputDevices: [2])
        // (holders, capture status the supervisor reports, seconds since the previous tick)
        let script: [([HolderObservation], Bool, TimeInterval)] = [
            ([a], false, 0),       // capture down: no session
            ([a], true, 2),        // capture up: session opens in the second step of the same tick
            ([a, b], true, 2),
            ([b], true, 2),        // a drains
            ([b], false, 2),       // capture drops; a's session must stay
            ([a, b], true, 2),     // a reclaims
            ([], true, 2),
            ([], true, 6),         // both expire
            ([b], true, 2),        // b returns as a fresh session
        ]
        for (holders, capturing, dt) in script {
            mono += dt
            processSource.processes = holders
            supervisor.statusToReturn = CaptureStatus(isCapturing: capturing, health: capturing ? .capturing : .idle)
            controller.pollOnce()
            registry.append(Data(count: 3200)) // gives open sessions bytes so listSessions() shows them
            let registryOpen = Set(registry.listSessions().filter(\.isOpen).map(\.bundleID))
            XCTAssertEqual(registryOpen, controller.reducerOpenSessions, "after tick at t=\(mono)")
        }
    }

    // MARK: - 8. Second step in the same tick when apply changes isCapturing

    func test_sessionOpensInSameTickCaptureComesUp() {
        let registry = makeRegistry()
        let supervisor = FakeSupervisor()
        supervisor.statusToReturn = CaptureStatus(isCapturing: true, health: .capturing)
        let processSource = FakeProcessSource()
        let controller = SessionLifecycleController(
            supervisor: supervisor,
            registry: registry,
            holderSnapshot: processSource.snapshot,
            permission: { .authorized },
            monotonicNow: { 50 }
        )
        processSource.processes = [testApp]
        controller.pollOnce()
        XCTAssertTrue(registry.anySessionOpen, "first tick: step 1 saw isCapturing=false, apply returned true, step 2 opened the session")
        XCTAssertEqual(supervisor.applyCount, 1, "one apply per tick")
    }

    // MARK: - 9. Candidate devices reach the supervisor

    func test_demandCarriesDeviceCandidates_drainingKeptDeviceOnlyWithoutHolderDevices() {
        let registry = makeRegistry()
        let supervisor = FakeSupervisor()
        let processSource = FakeProcessSource()
        var mono: TimeInterval = 10
        let controller = SessionLifecycleController(
            supervisor: supervisor,
            registry: registry,
            holderSnapshot: processSource.snapshot,
            permission: { .authorized },
            monotonicNow: { mono }
        )
        processSource.processes = [testApp]
        controller.pollOnce()
        XCTAssertEqual(supervisor.lastDemand.first?.deviceIDs, [1])

        mono += 2
        processSource.processes = []
        controller.pollOnce()
        XCTAssertEqual(supervisor.lastDemand.count, 1, "draining app stays in demand")
        XCTAssertEqual(supervisor.lastDemand.first?.deviceIDs, [1], "kept live device is the candidate")
    }

    // MARK: - 10. User exclusion

    private func manualController(
        _ supervisor: FakeSupervisor,
        _ registry: SessionRegistry,
        _ source: FakeProcessSource,
        clock: @escaping () -> TimeInterval,
        pollInterval: TimeInterval = 2
    ) -> SessionLifecycleController {
        SessionLifecycleController(
            supervisor: supervisor, registry: registry, holderSnapshot: source.snapshot,
            permission: { .authorized }, pollInterval: pollInterval, gracePeriod: 5,
            monotonicNow: clock
        )
    }

    func test_excludeMidSession_drainsAndClosesAtExpiry_captureContinuesForOtherHolder_unexcludeReclaims() {
        let registry = makeRegistry()
        let supervisor = FakeSupervisor()
        let source = FakeProcessSource()
        var mono: TimeInterval = 100
        let controller = manualController(supervisor, registry, source, clock: { mono })
        source.processes = [
            HolderObservation(appID: "com.test.a", pid: 1, inputDevices: [1]),
            HolderObservation(appID: "com.test.b", pid: 2, inputDevices: [2]),
        ]
        controller.pollOnce()
        XCTAssertEqual(controller.reducerOpenSessions, ["com.test.a", "com.test.b"])

        controller.setExcludedGroups(["com.test.a"])
        controller.pollOnce()
        XCTAssertEqual(controller.reducerOpenSessions, ["com.test.a", "com.test.b"], "excluded app drains; session still open")
        XCTAssertTrue(supervisor.lastDemand.contains { $0.bundleID == "com.test.b" && $0.deviceIDs == [2] }, "capture continues for b")

        mono += 6
        controller.pollOnce()
        XCTAssertEqual(controller.reducerOpenSessions, ["com.test.b"], "a's session closes at grace expiry")
        XCTAssertFalse(supervisor.lastDemand.contains { $0.bundleID == "com.test.a" })

        controller.setExcludedGroups([])
        controller.pollOnce()
        XCTAssertEqual(controller.reducerOpenSessions, ["com.test.a", "com.test.b"], "un-excluded a demands again")
        XCTAssertTrue(supervisor.lastDemand.contains { $0.bundleID == "com.test.a" })
    }

    func test_excludeThenUnexcludeInsideGrace_keepsSameSession() {
        let registry = makeRegistry()
        let supervisor = FakeSupervisor()
        let source = FakeProcessSource()
        var mono: TimeInterval = 100
        let controller = manualController(supervisor, registry, source, clock: { mono })
        source.processes = [HolderObservation(appID: "com.test.a", pid: 1, inputDevices: [1])]
        controller.pollOnce()
        registry.append(Data(count: 3200))
        let id = registry.listSessions().first { $0.bundleID == "com.test.a" }?.stableId

        controller.setExcludedGroups(["com.test.a"])
        mono += 2
        controller.pollOnce()
        controller.setExcludedGroups([])
        mono += 2
        controller.pollOnce()
        XCTAssertNotNil(id)
        XCTAssertEqual(registry.listSessions().filter { $0.bundleID == "com.test.a" }.map(\.stableId), [id!])
        XCTAssertEqual(registry.listSessions().filter(\.isOpen).count, 1)
    }

    func test_builtInHolderNeverBecomesDemand() {
        let registry = makeRegistry()
        let supervisor = FakeSupervisor()
        let source = FakeProcessSource()
        let controller = manualController(supervisor, registry, source, clock: { 10 })
        source.processes = [HolderObservation(appID: "com.apple.CoreSpeech", pid: 1, inputDevices: [1])]
        controller.pollOnce()
        XCTAssertTrue(supervisor.lastDemand.isEmpty)
        XCTAssertTrue(controller.reducerOpenSessions.isEmpty)
    }

    func test_holdingNow_includesUserExcludedApp_hidesBuiltIn() {
        let registry = makeRegistry()
        let supervisor = FakeSupervisor()
        let source = FakeProcessSource()
        let controller = manualController(supervisor, registry, source, clock: { 10 })
        source.processes = [
            HolderObservation(appID: "com.test.a", pid: 1, inputDevices: [1]),
            HolderObservation(appID: "com.apple.CoreSpeech", pid: 2, inputDevices: [1]),
        ]
        controller.setExcludedGroups(["com.test.a"])
        controller.pollOnce()
        waitUntil { !controller.holdingNow.isEmpty }
        XCTAssertEqual(controller.holdingNow.map(\.group), ["com.test.a"])
    }

    func test_settingsChange_triggersImmediatePoll_notTheTimer() {
        let registry = makeRegistry()
        let supervisor = FakeSupervisor()
        let source = FakeProcessSource()
        source.processes = [HolderObservation(appID: "com.test.a", pid: 1, inputDevices: [1])]
        // Timer period 1 h: only the start tick and the exclusion-triggered tick can happen.
        let controller = manualController(supervisor, registry, source,
                                          clock: { Date().timeIntervalSince1970 }, pollInterval: 3600)
        controller.start()
        defer { controller.stop() }
        waitUntil { supervisor.applyCount >= 1 }
        let before = supervisor.applyCount

        controller.setExcludedGroups(["com.test.a"])
        waitUntil(timeout: 1.0) { supervisor.applyCount > before }
    }
}
