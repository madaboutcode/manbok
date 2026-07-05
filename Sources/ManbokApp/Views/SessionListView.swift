import SwiftUI
import ManbokCore

struct SessionListView: View {
    @EnvironmentObject private var viewModel: PopoverViewModel
    @FocusState private var focusedSessionID: UInt64?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let sessions = viewModel.sessions
                ForEach(Array(sessions.enumerated()), id: \.element.stableId) { index, snapshot in
                    SessionRowView(
                        snapshot: snapshot,
                        focusedSessionID: $focusedSessionID,
                        previousID: index > 0 ? sessions[index - 1].stableId : nil,
                        nextID: index < sessions.count - 1 ? sessions[index + 1].stableId : nil
                    )
                    if index < sessions.count - 1 {
                        Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 12)
                    }
                }
            }
        }
        .frame(maxHeight: 320)
    }
}
