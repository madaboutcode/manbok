import Foundation

extension SessionSummary {
    /// CLI/IPC: `id:1,dur_sec:9.2,start_ago_sec:300,end_ago_sec:120,open:0`
    public var ipcToken: String {
        let endPart: String
        if let endedSecondsAgo {
            endPart = "end_ago_sec:\(Self.formatSeconds(endedSecondsAgo))"
        } else {
            endPart = "end_ago_sec:"
        }
        return [
            "id:\(id)",
            "bytes:\(audioBytes)",
            "dur_sec:\(String(format: "%.1f", durationSeconds))",
            "start_ago_sec:\(Self.formatSeconds(startedSecondsAgo))",
            endPart,
            "open:\(isOpen ? 1 : 0)",
        ].joined(separator: ",")
    }

    /// Human line for `upil-appa dump --list` (stdout).
    public func displayLine() -> String {
        let dur = String(format: "%.1fs", durationSeconds)
        let started = Self.relativeLabel(secondsAgo: startedSecondsAgo, prefix: "started")
        let ended: String
        if isOpen {
            ended = "open"
        } else if let endedSecondsAgo {
            ended = Self.relativeLabel(secondsAgo: endedSecondsAgo, prefix: "ended")
        } else {
            ended = "ended —"
        }
        return String(format: "%3d  %8@  %-14@  %@", id, dur, ended, started)
    }

    private static func formatSeconds(_ value: TimeInterval) -> String {
        value.isFinite ? String(format: "%.0f", value) : "inf"
    }

    private static func relativeLabel(secondsAgo: TimeInterval, prefix: String) -> String {
        guard secondsAgo.isFinite else { return "\(prefix) —" }
        if secondsAgo < 60 {
            return "\(prefix) \(Int(secondsAgo))s ago"
        }
        if secondsAgo < 3600 {
            return "\(prefix) \(Int(secondsAgo / 60))m ago"
        }
        return "\(prefix) \(String(format: "%.1f", secondsAgo / 3600))h ago"
    }
}