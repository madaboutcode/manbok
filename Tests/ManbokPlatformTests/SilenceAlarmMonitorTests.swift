import Combine
import XCTest
import ManbokCore
@testable import ManbokPlatform

private final class RecordingNotifier: SilenceAlarmNotifying, @unchecked Sendable {
    private(set) var authorizationRequests = 0
    private(set) var posted: [SilenceAlarmNotice] = []
    private(set) var withdrawals = 0
    var answersImmediately = true
    private var answers: [@Sendable (Bool) -> Void] = []
    func requestAuthorization(_ completion: @escaping @Sendable (Bool) -> Void) {
        authorizationRequests += 1
        if answersImmediately { completion(true) } else { answers.append(completion) }
    }
    func answerPending(granted: Bool) { answers.forEach { $0(granted) }; answers = [] }
    func post(_ notice: SilenceAlarmNotice) { posted.append(notice) }
    func withdraw() { withdrawals += 1 }
}

final class SilenceAlarmMonitorTests: XCTestCase {
    private var now: TimeInterval = 0
    private let notifier = RecordingNotifier()

    private func makeMonitor(enabled: Bool = true, seconds: Int = 30) -> SilenceAlarmMonitor {
        SilenceAlarmMonitor(
            config: SilenceAlarmConfig(enabled: enabled, seconds: seconds),
            notifier: notifier,
            context: { (apps: ["Hex"], device: "MacBook Pro Microphone") },
            clock: { [unowned self] in now }
        )
    }

    private func drainMain() {
        let done = expectation(description: "main drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func test_silenceLongerThanDuration_postsOneNoticeAndPublishesStatus() {
        let m = makeMonitor()
        m.sessionsOpen(true)

        now = 29; m.tick()
        XCTAssertTrue(notifier.posted.isEmpty)

        now = 30; m.tick()
        now = 32; m.tick()
        now = 60; m.tick()
        drainMain()

        XCTAssertEqual(notifier.posted, [SilenceAlarmNotice(apps: ["Hex"], device: "MacBook Pro Microphone", silentSeconds: 30)])
        XCTAssertEqual(m.status, SilenceAlarmStatus(device: "MacBook Pro Microphone", seconds: 30))
    }

    func test_audibleChunk_withdrawsNoticeAndClearsStatus() {
        let m = makeMonitor()
        m.sessionsOpen(true)
        now = 31; m.tick()

        now = 40; m.audibleChunk()
        drainMain()

        XCTAssertEqual(notifier.withdrawals, 1)
        XCTAssertNil(m.status)
    }

    func test_sessionsClosing_clearsRaisedAlarm() {
        let m = makeMonitor()
        m.sessionsOpen(true)
        now = 31; m.tick()

        now = 33; m.sessionsOpen(false)
        drainMain()

        XCTAssertEqual(notifier.withdrawals, 1)
        XCTAssertNil(m.status)
    }

    func test_boundToLifecycleFlag_followsPublishedValue() {
        final class Flag: ObservableObject { @Published var open = false }
        let flag = Flag()
        let m = makeMonitor()
        m.bind(sessionsOpen: flag.$open)

        flag.open = true
        now = 30; m.tick()
        drainMain()

        XCTAssertEqual(notifier.posted.count, 1)
    }

    func test_disablingWhileRaised_clearsAlarm() {
        let m = makeMonitor()
        m.sessionsOpen(true)
        now = 31; m.tick()

        m.configure(SilenceAlarmConfig(enabled: false, seconds: 30))
        drainMain()

        XCTAssertEqual(notifier.withdrawals, 1)
        XCTAssertNil(m.status)
    }

    func test_switchingOn_requestsAuthorizationOncePerSwitch_notAtInit() {
        let m = makeMonitor(enabled: false)
        XCTAssertEqual(notifier.authorizationRequests, 0)

        m.configure(SilenceAlarmConfig(enabled: true, seconds: 30))
        m.configure(SilenceAlarmConfig(enabled: true, seconds: 60))
        XCTAssertEqual(notifier.authorizationRequests, 1)

        m.configure(SilenceAlarmConfig(enabled: false, seconds: 60))
        m.configure(SilenceAlarmConfig(enabled: true, seconds: 60))
        XCTAssertEqual(notifier.authorizationRequests, 2)
    }

    func test_alarmInitiallyEnabled_doesNotRequestAuthorization() {
        _ = makeMonitor(enabled: true)
        XCTAssertEqual(notifier.authorizationRequests, 0)
    }

    // MARK: - Notice held until authorization is answered

    func test_raiseBeforeAuthorizationAnswer_deliversOneNoticeAfterGrant() {
        notifier.answersImmediately = false
        let m = makeMonitor(enabled: false)
        m.sessionsOpen(true)
        now = 100
        m.configure(SilenceAlarmConfig(enabled: true, seconds: 30))
        m.tick()
        XCTAssertTrue(notifier.posted.isEmpty, "posting before authorization would be lost")

        now = 108
        notifier.answerPending(granted: true)
        notifier.answerPending(granted: true)

        XCTAssertEqual(notifier.posted.count, 1)
    }

    func test_clearBeforeAuthorizationAnswer_deliversNothing() {
        notifier.answersImmediately = false
        let m = makeMonitor(enabled: false)
        m.sessionsOpen(true)
        now = 100
        m.configure(SilenceAlarmConfig(enabled: true, seconds: 30))
        m.tick()

        now = 105; m.audibleChunk()
        notifier.answerPending(granted: true)

        XCTAssertTrue(notifier.posted.isEmpty)
        XCTAssertEqual(notifier.withdrawals, 1)
    }

    func test_deniedAuthorization_deliversNothing() {
        notifier.answersImmediately = false
        let m = makeMonitor(enabled: false)
        m.sessionsOpen(true)
        now = 100
        m.configure(SilenceAlarmConfig(enabled: true, seconds: 30))
        m.tick()

        notifier.answerPending(granted: false)

        XCTAssertTrue(notifier.posted.isEmpty)
    }

    func test_raiseAfterAuthorizationAnswered_postsImmediately() {
        let m = makeMonitor(enabled: false)
        m.sessionsOpen(true)
        now = 100
        m.configure(SilenceAlarmConfig(enabled: true, seconds: 30))
        m.tick()

        XCTAssertEqual(notifier.posted.count, 1)
    }
}
