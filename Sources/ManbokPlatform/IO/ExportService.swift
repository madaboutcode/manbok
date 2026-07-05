import AppKit
import Foundation
import ManbokCore

// MARK: - CONTRACT: ExportService
//
// GUARANTEES:
// - dumpToFinder(stableId:registry:appSlug:startTime:) -> URL?
//   WAV to temp, reveal in Finder. Returns URL on success, nil if session expired.
// - copyToClipboard(stableId:registry:appSlug:startTime:) -> URL?
//   WAV to temp, file URL on NSPasteboard. Returns URL on success, nil if expired.
// - Filename: manbok-<slug>-YYYYMMDD-HHMMSS.wav
//   slug = lowercased app display name, alphanumeric+hyphen only
//   timestamp = session start time, local timezone
//   Collision: -2, -3 suffix (never silent overwrite)
// - Raw-span dumps (CLI, no app identity): manbok-YYYYMMDD-HHMMSS.wav
//   (existing DumpPaths pattern, preserved for CLI compat — NOT this service's job)
//
// FAILURE BEHAVIOR:
// - Expired session -> nil. WAV write failure -> throws.
//
// DOES NOT:
// - Render UI feedback or open Audacity. Those are caller concerns.

/// Exports a session's PCM as WAV and hands it off to Finder or the pasteboard.
public enum ExportService {
    private static let log = AppLog(category: .export)
    /// Exports session audio as WAV, reveals in Finder. Returns file URL or nil if expired.
    public static func dumpToFinder(
        stableId: UInt64,
        registry: SessionRegistry,
        appSlug: String,
        startTime: Date
    ) throws -> URL? {
        guard let url = try writeSessionWAV(
            stableId: stableId, registry: registry, appSlug: appSlug, startTime: startTime
        ) else {
            return nil
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return url
    }

    /// Exports session audio as WAV, puts file URL on pasteboard. Returns URL or nil if expired.
    public static func copyToClipboard(
        stableId: UInt64,
        registry: SessionRegistry,
        appSlug: String,
        startTime: Date
    ) throws -> URL? {
        guard let url = try writeSessionWAV(
            stableId: stableId, registry: registry, appSlug: appSlug, startTime: startTime
        ) else {
            return nil
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        return url
    }

    // MARK: - Shared internals

    /// Writes the session's WAV to temp. Nil if the session is unknown or fully expired.
    static func writeSessionWAV(
        stableId: UInt64,
        registry: SessionRegistry,
        appSlug: String,
        startTime: Date
    ) throws -> URL? {
        guard let pcm = registry.snapshotForSession(stableId: stableId) else {
            log.info("writeSessionWAV: session \(stableId) expired or unknown")
            return nil
        }
        let wav = WavPCMEncoder.encode(pcm: pcm)
        let url = nextURL(appSlug: appSlug, startTime: startTime)
        try wav.write(to: url)
        log.info("writeSessionWAV: wrote \(wav.count) bytes → \(url.lastPathComponent)")
        return url
    }

    /// Generates the export filename with collision avoidance.
    static func nextURL(appSlug: String, startTime: Date) -> URL {
        let dir = FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: startTime)

        let slug = sanitizeSlug(appSlug)
        let base = "manbok-\(slug)-\(timestamp)"

        let candidate = dir.appendingPathComponent("\(base).wav")
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        var suffix = 2
        while true {
            let suffixed = dir.appendingPathComponent("\(base)-\(suffix).wav")
            if !FileManager.default.fileExists(atPath: suffixed.path) {
                return suffixed
            }
            suffix += 1
        }
    }

    /// Lowercased, alphanumeric + hyphen only.
    static func sanitizeSlug(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return lowered.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
