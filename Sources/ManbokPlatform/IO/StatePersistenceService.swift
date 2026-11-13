import Darwin
import Foundation
import ManbokCore

// MARK: - CONTRACT (StatePersistenceService)
//
// GUARANTEES
// - A checkpoint is a generation: directory `<state>/checkpoint-<seq>/` holding `ring.pcm` and `ring.json`.
//   `seq` is a monotonically increasing integer (highest existing + 1) also written in the manifest;
//   order is never taken from mtime.
// - save() writes both files into `<state>/checkpoint.tmp-<uuid>/`, fsyncs them, renames the directory to
//   its new `checkpoint-<seq>` name, then fsyncs the state directory. Nothing is ever replaced in place, so
//   a crash at any point leaves every earlier generation intact and the new one either absent or complete.
// - After a successful save, older generations and the legacy root files are deleted (not before).
// - restore() returns the newest generation whose manifest decodes, has the current format version, carries
//   the generation matching its directory, and whose manifest.ringFilledBytes equals the PCM file size.
//   An invalid newer generation is skipped (warning with the reason) in favour of the next complete one.
//   It then fsyncs the state directory (so a rename left unsynced by a crashed save is durable), deletes
//   older generations (not the one it returned) and every `checkpoint.tmp-*`, one persisted log line each.
//   Legacy root files are left in place.
// - The legacy layout (`ring.pcm`/`ring.json` at the state root) counts as the oldest generation: restore()
//   reads it only when no generation is complete, and never deletes it. It is deleted by the next
//   successful save(), the same point where older generations are deleted.
// - restore() leaves the restored generation on disk: the last saved checkpoint stays until the next
//   successful save replaces it, so a crash after launch loses nothing. Only older generations and
//   interrupted-save debris are deleted by restore().
// - save() and restore() are serialized by one process-wide lock.
// - restore() never throws; any failure logs a warning and yields nil or the next candidate.
//
// EXPECTS
// - Single writer process per state directory (see SingleInstance); the process-wide lock covers threads only.
//
// FAILURE BEHAVIOR
// - save() propagates I/O errors (disk full, permission denied); a failed save leaves earlier generations
//   untouched and removes its own temporary directory.
//
// DOES NOT
// - Encode/decode ring buffer contents beyond raw PCM bytes.
// - Choose retention policy or call sites for save/restore (see ManbokApp).

/// Persists ring buffer checkpoints (manifest + PCM) as generations under `~/.manbok/`.
public enum StatePersistenceService {
    private static let log = AppLog(category: .app)
    private static let lock = NSLock()
    private static let generationPrefix = "checkpoint-"
    private static let temporaryPrefix = "checkpoint.tmp-"
    private static let pcmName = "ring.pcm"
    private static let manifestName = "ring.json"

    public static func save(manifest: CheckpointManifest, ringData: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try AppStatePaths.ensureDirectory()
        let state = AppStatePaths.stateDirectory

        let seq = (generations(in: state).map(\.seq).max() ?? 0) + 1
        let staged = try stage(manifest: manifest, ringData: ringData, generation: seq, in: state)
        let final = state.appendingPathComponent("\(generationPrefix)\(seq)", isDirectory: true)
        do {
            try FileManager.default.moveItem(at: staged, to: final)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        try fsyncDirectory(state)

        for old in generations(in: state) where old.seq < seq {
            remove(old.url, why: "older than saved generation \(seq)")
        }
        removeLegacyFiles(why: "superseded by generation \(seq)")
        log.notice("saved checkpoint generation \(seq): pcm=\(ringData.count)B")
    }

    public static func restore() -> (CheckpointManifest, Data)? {
        lock.lock()
        defer { lock.unlock() }
        let state = AppStatePaths.stateDirectory

        let found = generations(in: state).sorted { $0.seq > $1.seq }
        var restored: (seq: Int, manifest: CheckpointManifest, pcm: Data)?
        for candidate in found {
            switch load(manifestURL: candidate.url.appendingPathComponent(manifestName),
                        pcmURL: candidate.url.appendingPathComponent(pcmName),
                        expectedGeneration: candidate.seq) {
            case .success(let (manifest, pcm)):
                restored = (candidate.seq, manifest, pcm)
            case .failure(let reason):
                log.warning("skipping \(candidate.url.lastPathComponent): \(reason.message)")
            }
            if restored != nil { break }
        }

        if let restored {
            // A save that died between rename and its directory fsync left this generation's name unsynced; make it durable before relying on it.
            do {
                try fsyncDirectory(state)
            } catch {
                log.warning("could not fsync state directory after restoring generation \(restored.seq): \(error)")   // FALLBACK-OK: contract "restore() never throws; any failure logs a warning"
            }
            for old in found where old.seq < restored.seq {
                remove(old.url, why: "older than restored generation \(restored.seq)")
            }
        }
        for tmp in temporaryDirectories(in: state) {
            remove(tmp, why: "interrupted save")
        }
        if let restored { return (restored.manifest, restored.pcm) }

        switch load(manifestURL: AppStatePaths.ringManifestURL, pcmURL: AppStatePaths.ringDataURL, expectedGeneration: nil) {
        case .success(let (manifest, pcm)):
            return (manifest, pcm)
        case .failure(let reason):
            if reason != .absent { log.warning("legacy checkpoint unusable: \(reason.message)") }
            return nil
        }
    }

    // MARK: - Testable internals

    /// Writes and fsyncs a complete generation into a fresh temporary directory without publishing it.
    /// A crash after this call and before the rename leaves exactly this directory behind.
    static func stage(manifest: CheckpointManifest, ringData: Data, generation: Int, in state: URL) throws -> URL {
        var stamped = manifest
        stamped.generation = generation
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(stamped)

        let dir = state.appendingPathComponent("\(temporaryPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        do {
            try writeSynced(ringData, to: dir.appendingPathComponent(pcmName))
            try writeSynced(manifestData, to: dir.appendingPathComponent(manifestName))
            try fsyncDirectory(dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return dir
    }

    private enum LoadFailure: Error, Equatable {
        case absent
        case invalid(String)
        var message: String {
            switch self {
            case .absent: return "files missing"
            case .invalid(let why): return why
            }
        }
    }

    private static func load(manifestURL: URL, pcmURL: URL, expectedGeneration: Int?) -> Result<(CheckpointManifest, Data), LoadFailure> {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return .failure(.absent) }
        let manifest: CheckpointManifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(CheckpointManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            return .failure(.invalid("manifest unreadable: \(error)"))
        }
        guard manifest.formatVersion == CheckpointManifest.currentFormatVersion else {
            return .failure(.invalid("formatVersion \(manifest.formatVersion) != current \(CheckpointManifest.currentFormatVersion)"))
        }
        if let expectedGeneration, manifest.generation != expectedGeneration {
            return .failure(.invalid("manifest generation \(String(describing: manifest.generation)) != directory \(expectedGeneration)"))
        }
        let pcm: Data
        do {
            pcm = try Data(contentsOf: pcmURL)
        } catch {
            return .failure(.invalid("ring.pcm unreadable: \(error)"))
        }
        guard pcm.count == manifest.ringFilledBytes else {
            return .failure(.invalid("ring.pcm size \(pcm.count) != manifest.ringFilledBytes \(manifest.ringFilledBytes)"))
        }
        return .success((manifest, pcm))
    }

    private struct Generation { let seq: Int; let url: URL }

    private static func entries(in state: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: state, includingPropertiesForKeys: nil)) ?? []   // FALLBACK-OK: absent state directory means no checkpoints yet
    }

    private static func generations(in state: URL) -> [Generation] {
        entries(in: state).compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(generationPrefix), let seq = Int(name.dropFirst(generationPrefix.count)) else { return nil }
            return Generation(seq: seq, url: url)
        }
    }

    private static func temporaryDirectories(in state: URL) -> [URL] {
        entries(in: state).filter { $0.lastPathComponent.hasPrefix(temporaryPrefix) }
    }

    private static func remove(_ url: URL, why: String) {
        do {
            try FileManager.default.removeItem(at: url)
            log.notice("removed \(url.lastPathComponent): \(why)")
        } catch {
            log.warning("could not remove \(url.lastPathComponent) (\(why)): \(error)")
        }
    }

    private static func removeLegacyFiles(why: String) {
        for url in [AppStatePaths.ringManifestURL, AppStatePaths.ringDataURL]
        where FileManager.default.fileExists(atPath: url.path) {
            remove(url, why: "legacy checkpoint file, \(why)")
        }
    }

    private static func writeSynced(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "open \(url.lastPathComponent) errno=\(errno)"]) }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "write \(url.lastPathComponent) errno=\(errno)"]) }
                offset += n
            }
        }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "fsync \(url.lastPathComponent) errno=\(errno)"]) }
    }

    private static func fsyncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "open dir errno=\(errno)"]) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "fsync dir errno=\(errno)"]) }
    }
}
