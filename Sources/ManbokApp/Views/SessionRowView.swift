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

    private var isThisPlaying: Bool {
        viewModel.playingSessionId == snapshot.stableId
    }

    private var isPreparing: Bool {
        isThisPlaying && !viewModel.playback.isPlaying && viewModel.playback.duration == 0
    }

    private var buttonsVisible: Bool {
        isHovered || isFocused || isThisPlaying
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                AppIconView(
                    bundleID: snapshot.bundleID,
                    displayName: snapshot.displayName.isEmpty ? "?" : snapshot.displayName
                )
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(snapshot.displayName.isEmpty ? "Unknown app" : snapshot.displayName)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Theme.cream)
                            .lineLimit(1)
                        if snapshot.isOpen {
                            Text("LIVE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.amberHot)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Theme.amber.opacity(0.14))
                                )
                        }
                        Spacer(minLength: 0)
                        Text(startTimeText)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.creamDim)
                    }
                    Text(durationText)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.creamFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                actionArea
            }

            waveformArea
            playbackTimeRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(liveRowBackground)
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
            case .space:
                viewModel.playSession(snapshot)
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
        .accessibilityAction(named: "Play audio") { viewModel.playSession(snapshot) }
        .accessibilityAction(named: "Dump WAV file") { performDump() }
        .accessibilityAction(named: "Copy WAV file") { performCopy() }
        .padding(.vertical, 2)
    }

    /// Warm amber card background for the row currently being recorded — see
    /// option-e-listening-post.html `.row.live`. Absent for non-live rows.
    @ViewBuilder
    private var liveRowBackground: some View {
        if snapshot.isOpen {
            RoundedRectangle(cornerRadius: 9)
                .fill(
                    LinearGradient(
                        colors: [Theme.amber.opacity(0.09), Theme.amber.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Theme.amber.opacity(0.22), lineWidth: 1)
                )
                .shadow(color: Theme.amber.opacity(0.06), radius: 16)
        }
    }

    @ViewBuilder
    private var waveformArea: some View {
        if isThisPlaying {
            PlaybackWaveformView(
                peaks: snapshot.peaks,
                isOpen: snapshot.isOpen,
                fraction: viewModel.playback.progressFraction
            ) { fraction in
                viewModel.playback.seek(toFraction: fraction)
            }
        } else {
            WaveformView(peaks: snapshot.peaks, isOpen: snapshot.isOpen)
        }
    }

    @ViewBuilder
    private var playbackTimeRow: some View {
        if isThisPlaying {
            HStack {
                Text(formatPlaybackTime(viewModel.playback.currentTime))
                    .font(Theme.mono(10, weight: .medium))
                    .foregroundStyle(Theme.amberHot)
                Text("/")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.creamFaint)
                Text(formatPlaybackTime(viewModel.playback.duration))
                    .font(Theme.mono(10, weight: .medium))
                    .foregroundStyle(Theme.amberHot)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        ZStack(alignment: .trailing) {
            if copiedFeedback {
                Label("Copied", systemImage: "checkmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tapeGreen)
            } else {
                HStack(spacing: 4) {
                    Button(action: { viewModel.playSession(snapshot) }) {
                        ZStack {
                            actionButtonChrome(tinted: true)
                            if isPreparing {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.6)
                                    .tint(Theme.amber)
                            } else {
                                Image(systemName: isThisPlaying && viewModel.playback.isPlaying
                                      ? "pause.fill" : "play.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.amber)
                            }
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isPreparing)
                    .accessibilityLabel(isPreparing ? "Loading"
                                        : isThisPlaying && viewModel.playback.isPlaying
                                        ? "Pause" : "Play")

                    Button(action: performDump) {
                        ZStack {
                            actionButtonChrome(tinted: false)
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.creamDim)
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dump WAV file")

                    Button(action: performCopy) {
                        ZStack {
                            actionButtonChrome(tinted: false)
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.creamDim)
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy WAV file")
                }
                .opacity(errorMessage == nil && buttonsVisible ? 1 : 0)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.danger)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityLabel("Export error: \(errorMessage)")
            }
        }
        .frame(minHeight: 24, alignment: .trailing)
    }

    /// 21×21 instrument-panel button chrome drawn inside a 24pt hit target
    /// (see option-e-listening-post.html `.icon-btn`). `tinted` applies the
    /// amber play/pause treatment; other actions use the neutral hairline.
    private func actionButtonChrome(tinted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(0.02))
            .frame(width: 21, height: 21)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tinted ? Theme.amber.opacity(0.3) : Theme.lineStrong, lineWidth: 1)
            )
    }

    private func formatPlaybackTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Start time only — the end is derivable (duration sits on the next line), and the
    /// day is carried by the section header above the row, not repeated per row.
    private var startTimeText: String {
        Self.timeFormatter.string(from: snapshot.startedAt)
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
        // VoiceOver reads rows individually, so each row carries the day context that
        // sighted users get from the section header above it.
        let day = DayLabel.text(for: snapshot.startedAt)
        let start = Self.timeFormatter.string(from: snapshot.startedAt)
        let minutes = Int((snapshot.durationSeconds / 60).rounded())
        var label = "\(snapshot.displayName), \(day) \(start), \(minutes) minutes"
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
