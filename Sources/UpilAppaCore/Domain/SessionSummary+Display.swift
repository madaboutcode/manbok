import Foundation

extension SessionSummary {
    /// CLI/IPC: `id:1,dur_sec:9.2,start_ago_sec:300,end_ago_sec:120,open:0,app:Zoom`
    public var ipcToken: String {
        let endPart: String
        if let endedSecondsAgo {
            endPart = "end_ago_sec:\(Self.formatSeconds(endedSecondsAgo))"
        } else {
            endPart = "end_ago_sec:"
        }
        var parts = [
            "id:\(id)",
            "bytes:\(audioBytes)",
            "dur_sec:\(String(format: "%.1f", durationSeconds))",
            "start_ago_sec:\(Self.formatSeconds(startedSecondsAgo))",
            endPart,
            "open:\(isOpen ? 1 : 0)",
        ]
        if let appName {
            parts.append("app:\(appName)")
        }
        return parts.joined(separator: ",")
    }

    /// Human line for `upil-appa dump --list` (stdout).
    /// Compact single-line (no rule/box). Prefer `SessionSummary.table(...)` for the list command.
    public func displayLine() -> String {
        let dur = String(format: "%.1fs", durationSeconds)
        let ended = isOpen ? "open" : (endedSecondsAgo.map(Self.shortRelative) ?? "—")
        let started = Self.shortRelative(secondsAgo: startedSecondsAgo)
        let app = appName ?? ""
        // Compact, aligned single line using same short labels as the ruled table.
        return String(format: "%3d  %6@  %5@  %7@  %@", id, dur, ended, started, app)
    }

    /// Modern ruled list for `upil-appa dump --list` / `sessions`.
    /// Clean header + unicode rule (no enclosing box) using dynamic column alignment.
    /// "TUI" visual only — no ANSI, no external deps.
    public static func table(_ sessions: [SessionSummary]) -> String {
        if sessions.isEmpty {
            return "no sessions (record in another app, or ring empty)"
        }

        struct Row {
            let id: String
            let dur: String
            let ended: String
            let started: String
            let app: String
        }

        let rows = sessions.map { s in
            let dur = String(format: "%.1fs", s.durationSeconds)
            let ended: String
            if s.isOpen {
                ended = "open"
            } else if let e = s.endedSecondsAgo {
                ended = Self.shortRelative(secondsAgo: e)
            } else {
                ended = "—"
            }
            let started = Self.shortRelative(secondsAgo: s.startedSecondsAgo)
            return Row(id: "\(s.id)", dur: dur, ended: ended, started: started, app: s.appName ?? "")
        }

        // Dynamic widths (content only; inter-column gap added at join time).
        func colWidth(_ keyPath: KeyPath<Row, String>, header: String) -> Int {
            let dataMax = rows.map { $0[keyPath: keyPath].count }.max() ?? 0
            return max(dataMax, header.count)
        }
        let wID      = colWidth(\.id,      header: "#")
        let wDur     = colWidth(\.dur,     header: "dur")
        let wEnded   = colWidth(\.ended,   header: "ended")
        let wStarted = colWidth(\.started, header: "started")
        let wApp     = colWidth(\.app,     header: "app")
        let widths   = [wID, wDur, wEnded, wStarted, wApp]

        // Data right-align for #/dur/time cols; app left. Headers always left.
        let dataRight = [true, true, true, true, false]

        func pad(_ text: String, to width: Int, right: Bool) -> String {
            if text.count >= width { return text }
            let p = String(repeating: " ", count: width - text.count)
            return right ? (p + text) : (text + p)
        }

        let headerTexts = ["#", "dur", "ended", "started", "app"]
        let headerParts = headerTexts.enumerated().map { i, txt in
            pad(txt, to: widths[i], right: false) // headers left-aligned
        }
        let rawHeader = headerParts.joined(separator: "   ")

        // rtrim only trailing ws (preserve inter-column spacing)
        func rtrim(_ s: String) -> String {
            s.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        let headerLine = rtrim(rawHeader)

        // The modern "rule" under the header (per-column underlines, joined with gaps).
        // Keep the rule at full allocated width so it visually caps even the last column.
        let ruleParts = widths.map { w in String(repeating: "━", count: w) }
        let ruleLine = ruleParts.joined(separator: "   ")

        var dataLines: [String] = []
        for r in rows {
            let parts = [
                pad(r.id,      to: widths[0], right: dataRight[0]),
                pad(r.dur,     to: widths[1], right: dataRight[1]),
                pad(r.ended,   to: widths[2], right: dataRight[2]),
                pad(r.started, to: widths[3], right: dataRight[3]),
                pad(r.app,     to: widths[4], right: dataRight[4]),
            ]
            dataLines.append(rtrim(parts.joined(separator: "   ")))
        }

        // Small indent to match historical "  # " look from the old header.
        let indent = "  "
        return ([headerLine, ruleLine] + dataLines)
            .map { indent + $0 }
            .joined(separator: "\n")
    }

    private static func formatSeconds(_ value: TimeInterval) -> String {
        value.isFinite ? String(format: "%.0f", value) : "inf"
    }

    /// Compact relative time for table cells (no prefix, no "ago").
    /// Column header provides the "ended / started" context.
    private static func shortRelative(secondsAgo: TimeInterval) -> String {
        guard secondsAgo.isFinite else { return "—" }
        if secondsAgo < 60 {
            return "\(Int(secondsAgo))s"
        }
        if secondsAgo < 3600 {
            return "\(Int(secondsAgo / 60))m"
        }
        return String(format: "%.1fh", secondsAgo / 3600)
    }
}