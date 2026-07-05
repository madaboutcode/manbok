import SwiftUI
import ManbokCore

struct SessionRowView: View {
    let snapshot: SessionRegistry.SessionSnapshot
    var focusedSessionID: FocusState<UInt64?>.Binding
    let previousID: UInt64?
    let nextID: UInt64?

    @EnvironmentObject private var viewModel: PopoverViewModel

    @State private var isHovered = false
    @State private var copiedFeedback = false
    @State private var errorMessage: String?
    @State private var feedbackTask: Task<Void, Never>?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private var isFocused: Bool {
        focusedSessionID.wrappedValue == snapshot.stableId
    }

    private var buttonsVisible: Bool {
        isHovered || isFocused
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AppIconView(
                bundleID: snapshot.bundleID,
                displayName: snapshot.displayName.isEmpty ? "?" : snapshot.displayName
            )
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(snapshot.displayName.isEmpty ? "Unknown app" : snapshot.displayName)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                    if snapshot.isOpen {
                        Text("· Recording")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                    }
                    Spacer(minLength: 0)
                    Text(timeRangeText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text(durationText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                WaveformView(peaks: snapshot.peaks, isOpen: snapshot.isOpen)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionArea
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .focusable(true)
        .focusEffectDisabled()
        .focused(focusedSessionID, equals: snapshot.stableId)
        .onHover { isHovered = $0 }
        .onKeyPress { press in
            switch press.key {
            case .return:
                performDump()
                return .handled
            case .downArrow:
                if let nextID { focusedSessionID.wrappedValue = nextID }
                return .handled
            case .upArrow:
                if let previousID { focusedSessionID.wrappedValue = previousID }
                return .handled
            default:
                if press.characters.lowercased() == "c", press.modifiers.contains(.command) {
                    performCopy()
                    return .handled
                }
                return .ignored
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityAction(named: "Dump WAV file") { performDump() }
        .accessibilityAction(named: "Copy WAV file") { performCopy() }
    }

    @ViewBuilder
    private var actionArea: some View {
        ZStack(alignment: .trailing) {
            if copiedFeedback {
                Label("Copied", systemImage: "checkmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 6) {
                    Button(action: performDump) {
                        Image(systemName: "arrow.down.circle")
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dump WAV file")

                    Button(action: performCopy) {
                        Image(systemName: "doc.on.doc")
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy WAV file")
                }
                .opacity(errorMessage == nil && buttonsVisible ? 1 : 0)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityLabel("Export error: \(errorMessage)")
            }
        }
        .frame(minWidth: 68, minHeight: 24, alignment: .trailing)
    }

    private var timeRangeText: String {
        let startStr = Self.timeFormatter.string(from: snapshot.startedAt)
        guard let endedAt = snapshot.endedAt else {
            return "\(startStr) –"
        }
        let endStr = Self.timeFormatter.string(from: endedAt)
        if let startSuffix = startStr.split(separator: " ").last,
           let endSuffix = endStr.split(separator: " ").last,
           startSuffix == endSuffix,
           startStr.contains(" ") {
            let trimmedStart = startStr.replacingOccurrences(of: " \(startSuffix)", with: "")
            return "\(trimmedStart)–\(endStr)"
        }
        return "\(startStr)–\(endStr)"
    }

    private var durationText: String {
        let total = Int(snapshot.durationSeconds.rounded())
        if total < 60 {
            return "\(total)s"
        }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
    }

    private var accessibilityLabelText: String {
        let start = Self.timeFormatter.string(from: snapshot.startedAt)
        let minutes = Int((snapshot.durationSeconds / 60).rounded())
        var label: String
        if let endedAt = snapshot.endedAt {
            let end = Self.timeFormatter.string(from: endedAt)
            label = "\(snapshot.displayName), \(start) to \(end), \(minutes) minutes"
        } else {
            label = "\(snapshot.displayName), started \(start), \(minutes) minutes"
        }
        if snapshot.isOpen {
            label += ", recording"
        }
        return label
    }

    private func performDump() {
        guard viewModel.dumpSession(snapshot) != nil else {
            showErrorIfSessionStillExists()
            return
        }
    }

    private func performCopy() {
        guard viewModel.copySession(snapshot) else {
            showErrorIfSessionStillExists()
            return
        }
        showCopiedFeedback()
    }

    private func showErrorIfSessionStillExists() {
        let stillExists = viewModel.sessions.contains { $0.stableId == snapshot.stableId }
        if stillExists {
            showError()
        }
    }

    private func showCopiedFeedback() {
        feedbackTask?.cancel()
        errorMessage = nil
        copiedFeedback = true
        feedbackTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { copiedFeedback = false }
        }
    }

    private func showError() {
        feedbackTask?.cancel()
        copiedFeedback = false
        errorMessage = "Couldn't export"
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Couldn't export" as NSString,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        feedbackTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { errorMessage = nil }
        }
    }
}
