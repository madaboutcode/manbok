import XCTest
@testable import ManbokCore

final class SessionRegistryTests: XCTestCase {
    // MARK: - Test helpers

    /// byte = offset % 251, recognizable and collision-resistant enough for these tests.
    private func patternedByte(_ absoluteOffset: Int64) -> UInt8 {
        UInt8(truncatingIfNeeded: absoluteOffset % 251)
    }

    private func patternedData(startingAtAbsoluteOffset start: Int64, count: Int) -> Data {
        var data = Data(capacity: count)
        for index in 0 ..< count {
            data.append(patternedByte(start + Int64(index)))
        }
        return data
    }

    // MARK: - Open/close lifecycle, stable ids

    func testOpenSessionAssignsMonotonicStableIds() {
        let registry = SessionRegistry(ringCapacity: 10_000)
        let id1 = registry.openSession(bundleID: "app1", displayName: "App1")
        let id2 = registry.openSession(bundleID: "app2", displayName: "App2")
        let id3 = registry.openSession(bundleID: "app3", displayName: "App3")
        XCTAssertEqual(id1, 1)
        XCTAssertEqual(id2, 2)
        XCTAssertEqual(id3, 3)
    }

    func testReopeningAlreadyOpenBundleIDReturnsSameStableIdNotADuplicate() {
        let registry = SessionRegistry(ringCapacity: 10_000)
        let first = registry.openSession(bundleID: "app1", displayName: "App1")
        let second = registry.openSession(bundleID: "app1", displayName: "App1 renamed mid-flight")
        XCTAssertEqual(first, second)

        registry.append(Data(repeating: 0x11, count: 100))
        registry.closeSession(bundleID: "app1")
        XCTAssertEqual(registry.listSessions().count, 1, "second openSession call must not create a duplicate")
    }

    func testMultipleAppsCanBeOpenConcurrently() {
        let registry = SessionRegistry(ringCapacity: 10_000)
        registry.openSession(bundleID: "app1", displayName: "App1")
        registry.openSession(bundleID: "app2", displayName: "App2")
        XCTAssertTrue(registry.anySessionOpen)

        registry.append(Data(repeating: 0x11, count: 100))
        let sessions = registry.listSessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.allSatisfy(\.isOpen))
    }

    func testCloseSessionFinalizesAndMovesToClosedList() {
        let registry = SessionRegistry(ringCapacity: 10_000)
        let id = registry.openSession(bundleID: "app1", displayName: "App1")
        registry.append(Data(repeating: 0xAA, count: 800))
        registry.closeSession(bundleID: "app1")

        let sessions = registry.listSessions()
        XCTAssertEqual(sessions.count, 1)
        let session = sessions[0]
        XCTAssertEqual(session.stableId, id)
        XCTAssertEqual(session.bundleID, "app1")
        XCTAssertEqual(session.displayName, "App1")
        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(session.audioBytes, 800)
        XCTAssertNotNil(session.endedAt)
        XCTAssertEqual(registry.snapshotForSession(stableId: id), Data(repeating: 0xAA, count: 800))
    }

    func testCloseSessionWithNoOpenSessionIsNoOp() {
        let registry = SessionRegistry(ringCapacity: 10_000)
        registry.closeSession(bundleID: "app1")
        XCTAssertEqual(registry.listSessions().count, 0)
        XCTAssertFalse(registry.anySessionOpen)
    }

    func testListSessionsOrderedNewestStartFirst() {
        let registry = SessionRegistry(ringCapacity: 10_000)
        let idA = registry.openSession(bundleID: "a", displayName: "A")
        registry.append(Data(repeating: 0x11, count: 100))
        registry.closeSession(bundleID: "a")

        let idB = registry.openSession(bundleID: "b", displayName: "B")
        registry.append(Data(repeating: 0x22, count: 100))
        registry.closeSession(bundleID: "b")

        let sessions = registry.listSessions()
        XCTAssertEqual(sessions.map(\.stableId), [idB, idA], "newest-start-first")
    }

    func testOpenSessionLongerThanRingClampsToCapacity() {
        let registry = SessionRegistry(ringCapacity: 1_000)
        registry.openSession(bundleID: "app1", displayName: "App1")
        registry.append(Data(repeating: 0xAA, count: 1_500))

        let sessions = registry.listSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertLessThanOrEqual(sessions[0].audioBytes, 1_000)

        let snap = registry.snapshotForSession(stableId: sessions[0].stableId)
        XCTAssertEqual(snap?.count, sessions[0].audioBytes)
    }

    // MARK: - Snapshot / expiry

    func testSnapshotForUnknownStableIdReturnsNil() {
        let registry = SessionRegistry(ringCapacity: 10_000)
        XCTAssertNil(registry.snapshotForSession(stableId: 999))
    }

    func testSessionExpiresExactlyAtRingWrapBoundary() {
        // Boundary rule per design: a session ending exactly at the new oldestValidOffset
        // counts as expired (matches BufferPolicy.sessionsLost's `endTotalOffset <=` cutoff).
        let registry = SessionRegistry(ringCapacity: 1_000)
        let idOld = registry.openSession(bundleID: "app1", displayName: "App1")
        registry.append(Data(repeating: 0x11, count: 400))
        registry.closeSession(bundleID: "app1") // offset 0..<400

        registry.openSession(bundleID: "app2", displayName: "App2")
        registry.append(Data(repeating: 0x22, count: 1_000))
        registry.closeSession(bundleID: "app2")
        // total written = 1400, filled = 1000, oldestValidOffset = 400 -> app1's end (400)
        // sits exactly at the cutoff.

        let sessions = registry.listSessions()
        XCTAssertEqual(sessions.count, 1, "session ending exactly at the cutoff must be expired")
        XCTAssertEqual(sessions[0].bundleID, "app2")
        XCTAssertNil(registry.snapshotForSession(stableId: idOld))
    }

    func testPartiallyOverwrittenClosedSessionExpiresWhole() {
        // Glossary: "A closed session vanishes as a whole the moment its beginning is
        // overwritten." Once the ring wraps past a session's start offset, the entire
        // session disappears — no clamping to surviving bytes.
        let registry = SessionRegistry(ringCapacity: 1_000)
        let id1 = registry.openSession(bundleID: "app1", displayName: "App1")
        registry.append(Data(repeating: 0x11, count: 600))
        registry.closeSession(bundleID: "app1") // offset 0..<600

        let id2 = registry.openSession(bundleID: "app2", displayName: "App2")
        registry.append(Data(repeating: 0x22, count: 500))
        registry.closeSession(bundleID: "app2")
        // total written = 1100, filled = 1000, oldestValidOffset = 100.
        // app1 start (0) < 100 -> expired whole, even though bytes 100..600 survive.
        // app2: offset 600..<1100, fully intact.

        let sessions = registry.listSessions()
        XCTAssertEqual(sessions.count, 1, "app1 expired whole — its start was overwritten")
        XCTAssertEqual(sessions[0].stableId, id2)
        XCTAssertNil(registry.snapshotForSession(stableId: id1), "expired session returns nil")
    }

    // MARK: - Feature test: overlapping per-app views over one shared ring

    func testConcurrentAppsShareRingButTrackIndependentByteRanges() {
        let registry = SessionRegistry(ringCapacity: 10_000)

        let idApp1 = registry.openSession(bundleID: "app1", displayName: "App1")
        registry.append(Data(repeating: 0xAA, count: 100)) // app1 only

        let idApp2 = registry.openSession(bundleID: "app2", displayName: "App2")
        registry.append(Data(repeating: 0xBB, count: 200)) // both apps see this chunk

        registry.closeSession(bundleID: "app1")
        registry.append(Data(repeating: 0xCC, count: 50)) // app2 only, after app1 closed

        let sessions = registry.listSessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.allSatisfy { $0.peaks.count == 100 })

        let app1 = try! XCTUnwrap(sessions.first { $0.stableId == idApp1 })
        XCTAssertFalse(app1.isOpen)
        XCTAssertEqual(app1.audioBytes, 300)
        XCTAssertEqual(
            registry.snapshotForSession(stableId: idApp1),
            Data(repeating: 0xAA, count: 100) + Data(repeating: 0xBB, count: 200)
        )

        let app2 = try! XCTUnwrap(sessions.first { $0.stableId == idApp2 })
        XCTAssertTrue(app2.isOpen)
        XCTAssertEqual(app2.audioBytes, 250)
        XCTAssertEqual(
            registry.snapshotForSession(stableId: idApp2),
            Data(repeating: 0xBB, count: 200) + Data(repeating: 0xCC, count: 50)
        )
    }

    // MARK: - Waveform peaks

    func testWaveformPeaksPopulatedOnClose() {
        let registry = SessionRegistry(ringCapacity: 100_000)
        registry.openSession(bundleID: "app1", displayName: "App1")

        var samples = [Int16](repeating: 0, count: 4_000)
        for index in 0 ..< samples.count {
            samples[index] = Int16(index % 30_000)
        }
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        registry.append(pcm)
        registry.closeSession(bundleID: "app1")

        let sessions = registry.listSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].peaks.count, 100)
        XCTAssertTrue(sessions[0].peaks.contains { $0 > 0 }, "real signal should produce non-zero peaks")
    }

    // MARK: - snapshotForDump (raw ring slice, no session framing)

    func testSnapshotForDumpReturnsRawRingSliceIndependentOfSessions() {
        let registry = SessionRegistry(ringCapacity: 10_000)
        registry.append(Data(repeating: 0xAA, count: 500))
        registry.append(Data(repeating: 0xBB, count: 500))

        let full = registry.snapshotForDump(minutes: nil)
        XCTAssertEqual(full.count, 1_000)

        let clamped = registry.snapshotForDump(minutes: 1)
        XCTAssertEqual(clamped.count, 1_000, "requested minutes clamp to filled bytes on a small ring")
    }

    // MARK: - Resize (SK2 — gates this section)

    func testResizeToSameCapacityIsNoOp() throws {
        let registry = SessionRegistry(ringCapacity: BufferPolicy.capacityBytes(for: .min10))
        registry.append(Data(repeating: 0xAA, count: 500))
        try registry.resize(to: .min10)
        XCTAssertEqual(registry.capacityBytes, BufferPolicy.capacityBytes(for: .min10))
        XCTAssertEqual(registry.filledBytes, 500)
    }

    func testResizeGrowKeepsAllSessionsAndCapacityIncreases() throws {
        let registry = SessionRegistry(ringCapacity: BufferPolicy.capacityBytes(for: .min5))
        let id = registry.openSession(bundleID: "app1", displayName: "App1")
        registry.append(Data(repeating: 0xAA, count: 1_000))
        registry.closeSession(bundleID: "app1")

        try registry.resize(to: .min10)

        XCTAssertEqual(registry.capacityBytes, BufferPolicy.capacityBytes(for: .min10))
        let sessions = registry.listSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].audioBytes, 1_000)
        XCTAssertEqual(registry.snapshotForSession(stableId: id), Data(repeating: 0xAA, count: 1_000))
    }

    /// Old ring wraps at a small custom capacity (SessionRegistry's init takes a raw byte
    /// count, not a BufferPolicy preset), then resizes UP to a real preset. Exercises
    /// ring.slice(lastBytes:)'s wrapped-read branch as resize's input — distinct from the
    /// never-wrapped case in the shrink test below — while staying fast (a few KB, not MB).
    func testResizeAfterOldRingHadWrappedPreservesSurvivingBytes() throws {
        let registry = SessionRegistry(ringCapacity: 1_000)
        let id = registry.openSession(bundleID: "app1", displayName: "App1")
        registry.append(patternedData(startingAtAbsoluteOffset: 0, count: 1_500))
        // Ring wrapped: totalWritten=1500, filled=1000, oldestValidOffset=500.

        try registry.resize(to: .min5)

        XCTAssertEqual(registry.capacityBytes, BufferPolicy.capacityBytes(for: .min5))
        XCTAssertEqual(registry.filledBytes, 1_000, "growing preserves exactly what had survived the wrap")

        let sessions = registry.listSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions[0].isOpen)
        XCTAssertEqual(sessions[0].audioBytes, 1_000)
        XCTAssertEqual(
            registry.snapshotForSession(stableId: id),
            patternedData(startingAtAbsoluteOffset: 500, count: 1_000)
        )

        // Ring keeps working post-resize: further appends and a close extend correctly.
        registry.append(patternedData(startingAtAbsoluteOffset: 1_500, count: 200))
        registry.closeSession(bundleID: "app1")
        let closed = try! XCTUnwrap(registry.listSessions().first)
        XCTAssertEqual(closed.audioBytes, 1_200)
        XCTAssertEqual(
            registry.snapshotForSession(stableId: id),
            patternedData(startingAtAbsoluteOffset: 500, count: 1_200)
        )
    }

    /// Slow by nature (per CLAUDE.md's ring-wrap test allowance): shrinking to a real preset
    /// requires writing past the target's real byte size (9.6 MB for .min5) to exercise
    /// expire-whole, since presets are fixed real-world sizes, not test-tunable.
    func testResizeShrinkExpiresSessionsWhoseStartNoLongerFits() throws {
        let registry = SessionRegistry() // default .min10 capacity (19,200,000 bytes)
        let idBefore = registry.openSession(bundleID: "before", displayName: "Before")
        registry.append(patternedData(startingAtAbsoluteOffset: 0, count: 100_000))
        registry.closeSession(bundleID: "before") // offset 0..<100_000

        let idAfter = registry.openSession(bundleID: "after", displayName: "After")
        registry.append(patternedData(startingAtAbsoluteOffset: 100_000, count: 9_700_000))
        registry.closeSession(bundleID: "after") // offset 100_000..<9_800_000

        // A third session that starts within the new capacity
        let idRecent = registry.openSession(bundleID: "recent", displayName: "Recent")
        registry.append(patternedData(startingAtAbsoluteOffset: 9_800_000, count: 100_000))
        registry.closeSession(bundleID: "recent") // offset 9_800_000..<9_900_000

        XCTAssertEqual(registry.filledBytes, 9_900_000)

        try registry.resize(to: .min5) // new capacity = 9_600_000
        // new oldestValidOffset = 9_900_000 - 9_600_000 = 300_000
        // 'before' start (0) < 300_000 -> expired whole
        // 'after' start (100_000) < 300_000 -> expired whole (glossary: expire-whole)
        // 'recent' start (9_800_000) >= 300_000 -> survives intact

        XCTAssertEqual(registry.capacityBytes, BufferPolicy.capacityBytes(for: .min5))

        let sessions = registry.listSessions()
        XCTAssertEqual(sessions.count, 1, "only the fully-intact session survives")
        XCTAssertNil(registry.snapshotForSession(stableId: idBefore))
        XCTAssertNil(registry.snapshotForSession(stableId: idAfter), "start overwritten -> expired whole")

        let recent = try! XCTUnwrap(sessions.first { $0.stableId == idRecent })
        XCTAssertEqual(recent.audioBytes, 100_000)
    }
}
