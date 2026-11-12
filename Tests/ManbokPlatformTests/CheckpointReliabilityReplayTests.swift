import XCTest
import ManbokCore
@testable import ManbokPlatform

/// Replays H18, H19, H20 from sm-inventory.md against StatePersistenceService (real file I/O in a temp dir).
final class CheckpointReliabilityReplayTests: XCTestCase {
    private func manifest(name: String, filled: Int, capacity: Int) -> CheckpointManifest {
        CheckpointManifest(
            ringCapacityBytes: capacity, ringFilledBytes: filled, ringTotalBytesWritten: Int64(filled),
            nextStableId: 2,
            sessions: [PersistedSession(stableId: 1, bundleID: name, displayName: name, startTotalOffset: 0,
                                        audioBytes: filled, startedAt: Date(), endedAt: Date())])
    }

    // H18. Mirrors ManbokApp.init lines 26-29: `restore()` then `clear()` before anything new is saved.
    func test_previousRunAudioSurvivesCrashRightAfterNextLaunch() throws {
        _ = installTempStateDirectory()
        try StatePersistenceService.save(manifest: manifest(name: "RUN1", filled: 64, capacity: 128),
                                         ringData: Data(repeating: 0xAA, count: 64))

        // launch of run 2 (ManbokApp.init)
        let restored = StatePersistenceService.restore()
        XCTAssertNotNil(restored, "precondition: run 2 restores run 1's checkpoint")
        StatePersistenceService.clear()
        // run 2 crashes here (kill -9) before any save. Run 3 launches:
        expectKnownBug("H18: clear() after restore() deletes the only copy; nothing saved until quit/STOP") {
            XCTAssertNotNil(StatePersistenceService.restore(),
                            "run 1's audio must still be on disk after run 2 crashed")
        }
    }

    // H19. Two real save() calls racing, each with its own consistent (manifest, pcm) pair, full-size rings
    // so the size check in restore() cannot tell the pairs apart.
    func test_restoreNeverPairsManifestWithPCMFromADifferentSave() throws {
        _ = installTempStateDirectory()
        let size = 4096
        let a = (manifest(name: "A", filled: size, capacity: size), Data(repeating: 0xAA, count: size))
        let b = (manifest(name: "B", filled: size, capacity: size), Data(repeating: 0xBB, count: size))

        let stop = ManagedAtomicFlag()
        let writers = DispatchGroup()
        for pair in [a, b] {
            DispatchQueue.global().async(group: writers) {
                while !stop.isSet { try? StatePersistenceService.save(manifest: pair.0, ringData: pair.1) }
            }
        }
        var mismatches = 0
        var restores = 0
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && mismatches == 0 {
            if let (m, pcm) = StatePersistenceService.restore() {
                restores += 1
                let expected: UInt8 = m.sessions.first?.displayName == "A" ? 0xAA : 0xBB
                if pcm.first != expected { mismatches += 1 }
            }
        }
        stop.set()
        writers.wait()
        print("[H19] restores=\(restores) mismatched pairs=\(mismatches)")
        XCTAssertGreaterThan(restores, 0, "harness precondition: some restores succeeded")
        expectKnownBug("H19: save() is two independent atomic writes with no lock/generation id") {
            XCTAssertEqual(mismatches, 0, "restore returned a manifest with PCM from another save")
        }
    }

    // H20. restore() returns nil without clearing (here: ring.pcm truncated), then a crash between the
    // PCM write and the manifest write of the NEXT save leaves old manifest + new PCM.
    func test_staleManifestIsNotPairedWithLaterPCM() throws {
        _ = installTempStateDirectory()
        let size = 64
        // Old run left a manifest and a damaged PCM.
        try StatePersistenceService.save(manifest: manifest(name: "OLD", filled: size, capacity: size),
                                         ringData: Data(repeating: 0xAA, count: size))
        try Data(repeating: 0xAA, count: 10).write(to: AppStatePaths.ringDataURL)  // truncate
        XCTAssertNil(StatePersistenceService.restore(), "precondition: damaged checkpoint is rejected")
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppStatePaths.ringManifestURL.path),
                      "precondition (H20): rejected checkpoint is not cleared")

        // New run starts fresh. Its save() step 1 (PCM write, same call as StatePersistenceService.save)
        // completes; the process dies before step 2 (manifest write).
        try Data(repeating: 0xBB, count: size).write(to: AppStatePaths.ringDataURL, options: .atomic)

        let restored = StatePersistenceService.restore()
        expectKnownBug("H20: contract says a crash between the writes leaves no manifest for the new PCM") {
            if let (m, pcm) = restored {
                XCTFail("restore paired manifest \(m.sessions.first?.displayName ?? "?") with PCM byte \(String(describing: pcm.first))")
            }
        }
    }
}

final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
