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
struct SessionListView: View {
    let sessions: [MockSession]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(sessions.enumerated()), id: \.element.stableId) { index, snapshot in
                SessionRowView(
                    snapshot: snapshot,
                    isThisPlaying: snapshot.stableId == 2,
                    playbackFraction: snapshot.stableId == 2 ? 0.46 : 0,
                    playbackCurrentTime: snapshot.stableId == 2 ? (2 * 60 + 47) : 0
                )
                if index < sessions.count - 1 {
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 12)
                }
            }
        }
    }
}
