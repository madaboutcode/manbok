import SwiftUI
import ManbokCore

struct SessionListView: View {
    @EnvironmentObject private var viewModel: PopoverViewModel
    @FocusState private var focusedSessionID: UInt64?

    var body: some View {
        ScrollView {
            let sessions = viewModel.sessions
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(dayGroups(sessions)) { group in
                    Section {
                        ForEach(group.entries, id: \.snapshot.stableId) { entry in
                            SessionRowView(
                                snapshot: entry.snapshot,
                                focusedSessionID: $focusedSessionID,
                                previousID: entry.index > 0
                                    ? sessions[entry.index - 1].stableId : nil,
                                nextID: entry.index < sessions.count - 1
                                    ? sessions[entry.index + 1].stableId : nil
                            )
                            // Hairline only between rows of the same day — a day
                            // boundary is already separated by the next group's header.
                            if entry.snapshot.stableId != group.entries.last?.snapshot.stableId {
                                Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 12)
                            }
                        }
                    } header: {
                        DaySectionHeader(label: group.label)
                    }
                }
            }
        }
        .frame(maxHeight: 320)
    }

    private struct DayGroup: Identifiable {
        let label: String
        // Global indices into the flat sessions array, so keyboard prev/next
        // navigation still crosses day boundaries.
        var entries: [(index: Int, snapshot: SessionRegistry.SessionSnapshot)]
        var id: String { label }
    }

    /// Groups consecutive sessions (already newest-first) by the calendar day they
    /// started on. Consecutive-run grouping keeps list order authoritative — no resort.
    private func dayGroups(_ sessions: [SessionRegistry.SessionSnapshot]) -> [DayGroup] {
        var groups: [DayGroup] = []
        for (index, snapshot) in sessions.enumerated() {
            let label = DayLabel.text(for: snapshot.startedAt)
            if let last = groups.indices.last, groups[last].label == label {
                groups[last].entries.append((index, snapshot))
            } else {
                groups.append(DayGroup(label: label, entries: [(index, snapshot)]))
            }
        }
        return groups
    }
}

/// Instrument-panel section rule: tracked-out uppercase day label with a hairline
/// running to the panel's right edge (same voice as MicroLabel / "TAPE · CHANNELS").
/// Doubles as the list's top rule — PopoverContentView drops its header/list divider
/// when the session list is showing. Opaque panel fill so rows scrolling beneath the
/// pinned header disappear behind it instead of bleeding through.
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
