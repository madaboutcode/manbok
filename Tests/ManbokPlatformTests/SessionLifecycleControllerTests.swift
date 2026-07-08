import XCTest
import ManbokCore
@testable import ManbokPlatform

// MARK: - CONTRACT: SessionLifecycleControllerTests
//
// Exercises SessionLifecycleController against a fake CaptureSupervising (the waist) and a
// fake process snapshot, using the real SessionRegistry (Core, hardware-free). Poll interval
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
    private var _processes: [AudioProcessInfo] = []

    var processes: [AudioProcessInfo] {
        get { lock.lock(); defer { lock.unlock() }; return _processes }
        set { lock.lock(); defer { lock.unlock() }; _processes = newValue }
    }

    func snapshot() -> [AudioProcessInfo] { processes }
}

final class SessionLifecycleControllerTests: XCTestCase {
    private let pollInterval: TimeInterval = 0.1
    private let gracePeriod: TimeInterval = 0.3

    private let testApp = AudioProcessInfo(pid: 4242, bundleID: "com.test.app", isRunningInput: true, deviceIDs: [])

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
            processSnapshot: processSource.snapshot,
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
        let stableIdBeforeDrain = registry.openSession(bundleID: testApp.bundleID, displayName: "unused")

        processSource.processes = []
        pump(gracePeriod * 0.5) // well inside the grace window — draining, not expired
        XCTAssertTrue(registry.anySessionOpen, "session must stay open while draining")

        processSource.processes = [testApp] // reclaim before drain expiry
        pump(gracePeriod * 2) // long past the ORIGINAL grace deadline

        XCTAssertTrue(registry.anySessionOpen, "reclaimed session must never have closed")
        XCTAssertEqual(
            registry.openSession(bundleID: testApp.bundleID, displayName: "unused"),
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
        waitUntil { supervisor.lastDemand.contains { $0.bundleID == testApp.bundleID } }
        guard let firstArrivedAt = supervisor.lastDemand.first(where: { $0.bundleID == testApp.bundleID })?.arrivedAt else {
            return XCTFail("expected a demand entry for the test app")
        }

        processSource.processes = [] // depart
        pump(gracePeriod * 0.5) // inside grace — still draining

        processSource.processes = [testApp] // reclaim before drain expiry
        waitUntil { supervisor.lastDemand.contains { $0.bundleID == testApp.bundleID } }
        guard let reclaimedArrivedAt = supervisor.lastDemand.first(where: { $0.bundleID == testApp.bundleID })?.arrivedAt else {
            return XCTFail("expected a demand entry for the reclaimed test app")
        }

        XCTAssertEqual(
            firstArrivedAt,
            reclaimedArrivedAt,
            "arrivedAt must be preserved across a depart-and-reclaim inside the drain grace period"
        )
    }
}
