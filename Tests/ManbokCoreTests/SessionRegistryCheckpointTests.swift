import XCTest
@testable import ManbokCore

final class SessionRegistryCheckpointTests: XCTestCase {
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

    func test_checkpoint_roundTrip_closedAndOpenSessions() {
        let registry = SessionRegistry(ringCapacity: 10_000)

        let closedId = registry.openSession(bundleID: "app1", displayName: "App1")
        registry.append(patternedData(startingAtAbsoluteOffset: 0, count: 500))
        registry.closeSession(bundleID: "app1")

        let openId = registry.openSession(bundleID: "app2", displayName: "App2")
        registry.append(patternedData(startingAtAbsoluteOffset: 500, count: 300))

        let beforeSessions = registry.listSessions().sorted { $0.stableId < $1.stableId }
        XCTAssertEqual(beforeSessions.count, 2)

        let (manifest, ringData) = registry.checkpoint()
        XCTAssertEqual(manifest.ringFilledBytes, ringData.count)
        XCTAssertEqual(manifest.sessions.count, 2)

        let restored = SessionRegistry(restoredFrom: manifest, ringData: ringData)
        let restoredSessions = restored.listSessions().sorted { $0.stableId < $1.stableId }

        XCTAssertEqual(restoredSessions.count, 2)
        XCTAssertTrue(restoredSessions.allSatisfy { !$0.isOpen }, "all restored sessions are closed")

        for (before, after) in zip(beforeSessions, restoredSessions) {
            XCTAssertEqual(after.stableId, before.stableId)
            XCTAssertEqual(after.bundleID, before.bundleID)
            XCTAssertEqual(after.displayName, before.displayName)
            XCTAssertEqual(after.audioBytes, before.audioBytes)
            XCTAssertEqual(after.startedAt, before.startedAt)
            XCTAssertNotNil(after.endedAt)
            XCTAssertEqual(after.peaks.count, 100)
            XCTAssertFalse(after.peaks.isEmpty)
        }

        XCTAssertEqual(restored.filledBytes, registry.filledBytes)

        // openId's frozen session must have gained an endedAt even though it was never closed
        // live; closedId's endedAt is preserved as-is.
        XCTAssertTrue(restoredSessions.contains { $0.stableId == closedId })
        XCTAssertTrue(restoredSessions.contains { $0.stableId == openId })

        // nextStableId preserved so future opens on the restored registry don't collide.
        let nextId = restored.openSession(bundleID: "app3", displayName: "App3")
        XCTAssertEqual(nextId, manifest.nextStableId)
    }

    func test_checkpoint_roundTrip_emptyRegistry() {
        let registry = SessionRegistry(ringCapacity: 10_000)
        let (manifest, ringData) = registry.checkpoint()

        XCTAssertEqual(manifest.sessions.count, 0)
        XCTAssertEqual(ringData.count, 0)
        XCTAssertEqual(manifest.ringFilledBytes, 0)

        let restored = SessionRegistry(restoredFrom: manifest, ringData: ringData)
        XCTAssertEqual(restored.listSessions().count, 0)
        XCTAssertEqual(restored.filledBytes, 0)
        XCTAssertFalse(restored.anySessionOpen)
        XCTAssertEqual(restored.capacityBytes, 10_000)
    }

    func test_checkpoint_restore_peaksMatchWaveformSamplerOnPCM() {
        let registry = SessionRegistry(ringCapacity: 100_000)

        var samples = [Int16](repeating: 0, count: 4_000)
        for index in 0 ..< samples.count {
            samples[index] = Int16(index % 30_000)
        }
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }

        registry.openSession(bundleID: "app1", displayName: "App1")
        registry.append(pcm)
        registry.closeSession(bundleID: "app1")

        let (manifest, ringData) = registry.checkpoint()
        let restored = SessionRegistry(restoredFrom: manifest, ringData: ringData)

        let restoredSession = try! XCTUnwrap(restored.listSessions().first)
        let expectedPeaks = WaveformSampler.peaks(from: pcm, buckets: 100)
        XCTAssertEqual(restoredSession.peaks, expectedPeaks)
    }
}
