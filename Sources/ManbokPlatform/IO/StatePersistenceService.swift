import Foundation
import ManbokCore

// MARK: - CONTRACT (StatePersistenceService)
//
// GUARANTEES
// - save() writes PCM first, then the manifest, each via atomic write-then-rename
//   (`Data.write(options: .atomic)`); a crash between the two leaves no manifest
//   for a stale/partial PCM file, so restore() safely returns nil.
// - restore() never throws — any failure (missing file, decode error, version
//   mismatch, size mismatch) logs a warning and returns nil.
// - restore() validates `manifest.formatVersion` against
//   `CheckpointManifest.currentFormatVersion` and `pcm.count == manifest.ringFilledBytes`.
// - clear() is idempotent — removing already-absent files is not an error.
//
// EXPECTS
// - `AppStatePaths.ensureDirectory()` has a writable parent (`~/.manbok/`).
//
// FAILURE BEHAVIOR
// - save() propagates I/O errors (disk full, permission denied) to the caller.
// - restore() swallows all errors and returns nil — caller treats nil as "start fresh".
//
// DOES NOT
// - Encode/decode ring buffer contents beyond raw PCM bytes.
// - Choose retention policy or call sites for save/restore (see SessionLifecycleController).

/// Persists ring buffer checkpoints (manifest + PCM) to `~/.manbok/`.
public enum StatePersistenceService {
    private static let log = AppLog(category: .app)

    public static func save(manifest: CheckpointManifest, ringData: Data) throws {
        try AppStatePaths.ensureDirectory()

        try ringData.write(to: AppStatePaths.ringDataURL, options: .atomic)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: AppStatePaths.ringManifestURL, options: .atomic)

        log.notice("saved checkpoint: pcm=\(ringData.count)B manifest=\(manifestData.count)B")
    }

    public static func restore() -> (CheckpointManifest, Data)? {
        let manifestURL = AppStatePaths.ringManifestURL
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let manifest: CheckpointManifest
        do {
            let manifestData = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(CheckpointManifest.self, from: manifestData)
        } catch {
            log.warning("failed to decode manifest: \(error)")
            return nil
        }

        guard manifest.formatVersion == CheckpointManifest.currentFormatVersion else {
            log.warning("manifest formatVersion \(manifest.formatVersion) != current \(CheckpointManifest.currentFormatVersion)")
            return nil
        }

        let pcmURL = AppStatePaths.ringDataURL
        guard FileManager.default.fileExists(atPath: pcmURL.path) else {
            log.warning("ring.pcm missing for existing manifest")
            return nil
        }

        let pcm: Data
        do {
            pcm = try Data(contentsOf: pcmURL)
        } catch {
            log.warning("failed to read ring.pcm: \(error)")
            return nil
        }

        guard pcm.count == manifest.ringFilledBytes else {
            log.warning("ring.pcm size \(pcm.count) != manifest.ringFilledBytes \(manifest.ringFilledBytes)")
            return nil
        }

        return (manifest, pcm)
    }

    public static func clear() {
        for url in [AppStatePaths.ringManifestURL, AppStatePaths.ringDataURL] {
            try? FileManager.default.removeItem(at: url)
        }
        log.info("cleared checkpoint state")
    }
}
