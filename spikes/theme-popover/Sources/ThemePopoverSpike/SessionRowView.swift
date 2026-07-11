import SwiftUI

/// Ported from Sources/ManbokApp/Views/SessionRowView.swift. Production drives this from
/// PopoverViewModel (hover/focus/playback state, dump/copy actions with async feedback);
/// this mock keeps only what's needed to render a convincing static frame:
///   - `snapshot` is the local `MockSession` mirror (see MockData.swift) instead of
///     SessionRegistry.SessionSnapshot (whose init isn't public outside ManbokCore).
///   - action buttons are always shown (`buttonsVisible` in production requires hover/focus,
///     which doesn't exist in an offscreen render) so the hero shot demonstrates the affordances.
///   - optional `isThisPlaying`/`playbackFraction`/`playbackCurrentTime` let one row show the
///     scrub-cursor + transport-time treatment production only shows during playback.
///   - hover/focus/keyboard/accessibility-action wiring and the copy/dump/error feedback
///     state machine are dropped entirely (nothing to click in a PNG).
struct SessionRowView: View {
    let snapshot: MockSession
    var isThisPlaying: Bool = false
    var playbackFraction: Double = 0
    var playbackCurrentTime: TimeInterval = 0

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

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
        .padding(.vertical, 2)
    }

    /// Warm amber card background for the row currently being recorded — absent for
    /// non-live rows.
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
                fraction: playbackFraction
            )
        } else {
            WaveformView(peaks: snapshot.peaks, isOpen: snapshot.isOpen)
        }
    }

    @ViewBuilder
    private var playbackTimeRow: some View {
        if isThisPlaying {
            HStack {
                Text(formatPlaybackTime(playbackCurrentTime))
                    .font(Theme.mono(10, weight: .medium))
                    .foregroundStyle(Theme.amberHot)
                Text("/")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.creamFaint)
                Text(formatPlaybackTime(snapshot.durationSeconds))
                    .font(Theme.mono(10, weight: .medium))
                    .foregroundStyle(Theme.amberHot)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        HStack(spacing: 4) {
            ZStack {
                actionButtonChrome(tinted: true)
                Image(systemName: isThisPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.amber)
            }
            .frame(width: 24, height: 24)

            ZStack {
                actionButtonChrome(tinted: false)
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.creamDim)
            }
            .frame(width: 24, height: 24)

            ZStack {
                actionButtonChrome(tinted: false)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.creamDim)
            }
            .frame(width: 24, height: 24)
        }
        .frame(minHeight: 24, alignment: .trailing)
    }

    /// 21×21 instrument-panel button chrome drawn inside a 24pt hit target.
    /// `tinted` applies the amber play/pause treatment; other actions use the neutral hairline.
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
}
