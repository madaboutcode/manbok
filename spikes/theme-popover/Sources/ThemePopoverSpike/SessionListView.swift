import SwiftUI

/// Ported from Sources/ManbokApp/Views/SessionListView.swift, with three mock-only
/// changes: sessions arrive as a plain array instead of from PopoverViewModel,
/// focus-state plumbing (@FocusState / keyboard nav between rows) is dropped, and
/// `ScrollView { LazyVStack { ... } }` becomes a plain `VStack`.
///
/// The ScrollView swap isn't cosmetic preference — it's a real ImageRenderer
/// limitation found empirically: LazyVStack only lays out rows that a live scroll
/// viewport reports as visible, and ImageRenderer never drives one, so the session
/// list rendered completely blank with the original ScrollView/LazyVStack. A plain
/// VStack always lays out every child, which is what a "show everything in one
/// static frame" hero shot wants anyway. Production's `maxHeight: 320` scroll cap is
/// dropped for the same reason — with it, offscreen rendering has nothing to
/// scroll, so the constraint would only ever clip, never scroll.
///
/// SPIKE UNDER TEST: rows are grouped under day section headers (TODAY / YESTERDAY /
/// weekday) and each row shows only its start time — the ring survives quit/restore,
/// so time-of-day alone is ambiguous, and the old start–end range double-encoded the
/// duration already printed inside the row.
struct SessionListView: View {
    let sessions: [MockSession]

    var body: some View {
        VStack(spacing: 0) {
            let groups = dayGroups
            ForEach(groups) { group in
                DaySectionHeader(label: group.label)
                ForEach(Array(group.sessions.enumerated()), id: \.element.stableId) { index, snapshot in
                    // The Safari row plays in both scenarios (hero id 2, multi-day id 12)
                    // so every static shot demonstrates the scrub-cursor treatment.
                    let isPlaying = snapshot.stableId == 2 || snapshot.stableId == 12
                    SessionRowView(
                        snapshot: snapshot,
                        isThisPlaying: isPlaying,
                        playbackFraction: isPlaying ? 0.46 : 0,
                        playbackCurrentTime: isPlaying ? (2 * 60 + 47) : 0
                    )
                    if index < group.sessions.count - 1 {
                        Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 12)
                    }
                }
            }
        }
    }

    private struct DayGroup: Identifiable {
        let label: String
        var sessions: [MockSession]
        var id: String { label }
    }

    /// Groups consecutive sessions (already newest-first) by the calendar day they
    /// started on. Consecutive-run grouping keeps list order authoritative — no resort.
    private var dayGroups: [DayGroup] {
        var groups: [DayGroup] = []
        for session in sessions {
            let label = DayLabel.text(for: session.startedAt)
            if let last = groups.indices.last, groups[last].label == label {
                groups[last].sessions.append(session)
            } else {
                groups.append(DayGroup(label: label, sessions: [session]))
            }
        }
        return groups
    }
}

/// Instrument-panel section rule: tracked-out uppercase day label with a hairline
/// running to the panel's right edge (same voice as MicroLabel / "TAPE · CHANNELS").
struct DaySectionHeader: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(Theme.mono(9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Theme.creamFaint)
                .fixedSize()
            Rectangle().fill(Theme.line).frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(Theme.bgPanel)
        .accessibilityAddTraits(.isHeader)
    }
}

enum DayLabel {
    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    /// "Today" / "Yesterday" / weekday name within the past week / "Jul 8" beyond.
    /// The ring holds at most 120 min of audio, so anything past a week only appears
    /// via an old checkpoint restore — rare, but it must still read unambiguously.
    static func text(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? Int.max
        if days < 7 {
            return weekdayFormatter.string(from: date)
        }
        return monthDayFormatter.string(from: date)
    }
}
