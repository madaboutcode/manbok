import Foundation

// MARK: - CONTRACT (DumpPaths)
//
// GUARANTEES
// - `nextURL()` returns a path under `FileManager.default.temporaryDirectory`.
// - Filename pattern: `manbok-YYYYMMDD-HHMMSS.wav` in the local timezone.
// - Parent directory exists before the URL is returned.
//
// DOES NOT
// - Open applications, delete old dumps, or write WAV bytes (see WavFileWriter).

/// Timestamped dump filenames under the system temporary directory.
public enum DumpPaths {
    private static let filenamePrefix = "manbok-"

    public static func nextURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let timestamp = formatter.string(from: Date())
        let filename = "\(filenamePrefix)\(timestamp).wav"
        return directory.appendingPathComponent(filename)
    }
}