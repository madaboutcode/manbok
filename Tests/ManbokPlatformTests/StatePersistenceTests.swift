import XCTest
import ManbokCore
@testable import ManbokPlatform

final class StatePersistenceTests: XCTestCase {
    private func manifest(_ name: String, filled: Int) -> CheckpointManifest {
        CheckpointManifest(
            ringCapacityBytes: filled, ringFilledBytes: filled, ringTotalBytesWritten: Int64(filled), nextStableId: 2,
            sessions: [PersistedSession(stableId: 1, bundleID: name, displayName: name, startTotalOffset: 0,
                                        audioBytes: filled, startedAt: Date(), endedAt: Date())])
    }

    private func names(_ state: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: state.path)) ?? []).sorted()
    }

    /// Publishes a generation without deleting older ones (save() would delete them).
    private func publish(_ name: String, byte: UInt8, generation: Int, in state: URL) throws {
        let staged = try StatePersistenceService.stage(
            manifest: manifest(name, filled: 32), ringData: Data(repeating: byte, count: 32), generation: generation, in: state)
        try FileManager.default.moveItem(at: staged, to: state.appendingPathComponent("checkpoint-\(generation)"))
    }

    func test_save_publishesNextGenerationAndDeletesOlderOnes() throws {
        let state = installTempStateDirectory()
        try StatePersistenceService.save(manifest: manifest("A", filled: 32), ringData: Data(repeating: 0xAA, count: 32))
        try StatePersistenceService.save(manifest: manifest("B", filled: 32), ringData: Data(repeating: 0xBB, count: 32))

        XCTAssertEqual(names(state), ["checkpoint-2"])
        let (m, pcm) = try XCTUnwrap(StatePersistenceService.restore())
        XCTAssertEqual(m.generation, 2)
        XCTAssertEqual(m.sessions.first?.displayName, "B")
        XCTAssertEqual(pcm.first, 0xBB)
    }

    func test_restore_crashAfterStagingBeforeRename_returnsPreviousGenerationAndRemovesTemp() throws {
        let state = installTempStateDirectory()
        try StatePersistenceService.save(manifest: manifest("PREV", filled: 32), ringData: Data(repeating: 0xAA, count: 32))
        _ = try StatePersistenceService.stage(manifest: manifest("NEWER", filled: 32),
                                              ringData: Data(repeating: 0xBB, count: 32), generation: 2, in: state)
        XCTAssertTrue(names(state).contains { $0.hasPrefix("checkpoint.tmp-") }, "precondition: crash debris present")

        let (m, pcm) = try XCTUnwrap(StatePersistenceService.restore())

        XCTAssertEqual(m.sessions.first?.displayName, "PREV")
        XCTAssertEqual(pcm.first, 0xAA)
        XCTAssertEqual(names(state), ["checkpoint-1"])
    }

    func test_restore_twoCompleteGenerations_newestWinsAndOlderIsDeleted() throws {
        let state = installTempStateDirectory()
        try publish("G9", byte: 0x09, generation: 9, in: state)
        try publish("G10", byte: 0x10, generation: 10, in: state)   // 10 > 9 numerically, but "10" < "9" as a string

        let (m, _) = try XCTUnwrap(StatePersistenceService.restore())

        XCTAssertEqual(m.sessions.first?.displayName, "G10")
        XCTAssertEqual(names(state), ["checkpoint-10"])
    }

    func test_restore_newestTruncated_fallsBackToOlderComplete() throws {
        let state = installTempStateDirectory()
        try publish("OLDER", byte: 0xAA, generation: 1, in: state)
        try publish("NEWEST", byte: 0xBB, generation: 2, in: state)
        try Data(repeating: 0xBB, count: 5).write(to: state.appendingPathComponent("checkpoint-2/ring.pcm"))

        let (m, pcm) = try XCTUnwrap(StatePersistenceService.restore())

        XCTAssertEqual(m.sessions.first?.displayName, "OLDER")
        XCTAssertEqual(pcm.first, 0xAA)
    }

    private func writeLegacy(_ name: String, byte: UInt8) throws {
        try Data(repeating: byte, count: 32).write(to: AppStatePaths.ringDataURL)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest(name, filled: 32)).write(to: AppStatePaths.ringManifestURL)
    }

    func test_restore_legacyRootLayout_returnsItAndLeavesFilesOnDisk() throws {
        let state = installTempStateDirectory()
        try writeLegacy("LEGACY", byte: 0xCC)

        let (m, pcm) = try XCTUnwrap(StatePersistenceService.restore())

        XCTAssertEqual(m.sessions.first?.displayName, "LEGACY")
        XCTAssertEqual(pcm.first, 0xCC)
        XCTAssertEqual(names(state), ["ring.json", "ring.pcm"])
    }

    func test_restore_legacyAfterCrash_restoresAgain() throws {
        _ = installTempStateDirectory()
        try writeLegacy("LEGACY", byte: 0xCC)

        _ = StatePersistenceService.restore()
        let second = try XCTUnwrap(StatePersistenceService.restore())

        XCTAssertEqual(second.0.sessions.first?.displayName, "LEGACY")
    }

    func test_save_afterLegacyRestore_removesLegacyFiles() throws {
        let state = installTempStateDirectory()
        try writeLegacy("LEGACY", byte: 0xCC)
        _ = StatePersistenceService.restore()

        try StatePersistenceService.save(manifest: manifest("RUN1", filled: 32), ringData: Data(repeating: 0xAA, count: 32))

        XCTAssertEqual(names(state), ["checkpoint-1"])
    }

    func test_restore_completeGenerationAndLegacy_prefersGenerationAndKeepsLegacyUntilSave() throws {
        let state = installTempStateDirectory()
        try publish("GEN", byte: 0xAA, generation: 1, in: state)
        try writeLegacy("LEGACY", byte: 0xCC)

        let (m, _) = try XCTUnwrap(StatePersistenceService.restore())
        XCTAssertEqual(m.sessions.first?.displayName, "GEN")
        XCTAssertEqual(names(state), ["checkpoint-1", "ring.json", "ring.pcm"])

        try StatePersistenceService.save(manifest: manifest("RUN2", filled: 32), ringData: Data(repeating: 0xBB, count: 32))
        XCTAssertEqual(names(state), ["checkpoint-2"])
    }

    func test_restore_allGenerationsInvalid_fallsBackToLegacy() throws {
        let state = installTempStateDirectory()
        try publish("BAD", byte: 0xAA, generation: 1, in: state)
        try Data().write(to: state.appendingPathComponent("checkpoint-1/ring.pcm"))
        try writeLegacy("LEGACY", byte: 0xCC)

        let (m, _) = try XCTUnwrap(StatePersistenceService.restore())
        XCTAssertEqual(m.sessions.first?.displayName, "LEGACY")
    }

    func test_restore_twiceWithoutSaveInBetween_returnsSameAudio() throws {
        let state = installTempStateDirectory()
        try StatePersistenceService.save(manifest: manifest("RUN1", filled: 32), ringData: Data(repeating: 0xAA, count: 32))

        let first = try XCTUnwrap(StatePersistenceService.restore())
        // launch crashes here (no save). Next launch:
        let second = try XCTUnwrap(StatePersistenceService.restore())

        XCTAssertEqual(first.1, second.1)
        XCTAssertEqual(second.0.sessions.first?.displayName, "RUN1")
        XCTAssertEqual(names(state), ["checkpoint-1"])
    }

    func test_saveAfterRestore_replacesRestoredGeneration() throws {
        let state = installTempStateDirectory()
        try StatePersistenceService.save(manifest: manifest("RUN1", filled: 32), ringData: Data(repeating: 0xAA, count: 32))
        _ = StatePersistenceService.restore()
        try StatePersistenceService.save(manifest: manifest("RUN2", filled: 32), ringData: Data(repeating: 0xBB, count: 32))

        XCTAssertEqual(names(state), ["checkpoint-2"])
    }
}
