import SwiftUI

/// Ported from Sources/ManbokApp/Views/PopoverContentView.swift. Production switches
/// content based on CaptureOrchestrator.micPermission / PopoverViewModel.sessions (both
/// @EnvironmentObject); here the same three states are selected explicitly by the caller
/// via `PopoverState` so each render is deterministic. Layout (VStack, dividers, 320pt
/// width, PanelBackgroundView, dark color scheme) is unchanged. Ring fill/capacity are
/// bytes, matching PopoverViewModel.ringFilled/ringCapacity exactly.
enum PopoverState {
    case sessions([MockSession], isRecording: Bool, ringFilledBytes: Int, ringCapacityBytes: Int)
    case empty(ringFilledBytes: Int, ringCapacityBytes: Int)
    case noAccess
}

struct PopoverContentView: View {
    let state: PopoverState

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                micDenied: isNoAccess,
                isRecording: isRecording,
                spinning: isRecording,
                ringFilledBytes: ringFilledBytes,
                ringCapacityBytes: ringCapacityBytes,
                sessionCount: sessionCount
            )
            Rectangle().fill(Theme.line).frame(height: 1)
            content
            Rectangle().fill(Theme.line).frame(height: 1)
            FooterView()
        }
        .frame(width: 320)
        .background(PanelBackgroundView().ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .noAccess:
            PermissionDeniedView()
        case .empty(let ringFilledBytes, let ringCapacityBytes):
            EmptyStateView(ringFilledBytes: ringFilledBytes, ringCapacityBytes: ringCapacityBytes)
        case .sessions(let sessions, _, _, _):
            SessionListView(sessions: sessions)
        }
    }

    private var isNoAccess: Bool {
        if case .noAccess = state { return true }
        return false
    }

    private var isRecording: Bool {
        if case .sessions(_, let isRecording, _, _) = state { return isRecording }
        return false
    }

    private var ringFilledBytes: Int {
        switch state {
        case .sessions(_, _, let filled, _): return filled
        case .empty(let filled, _): return filled
        case .noAccess: return 0
        }
    }

    private var ringCapacityBytes: Int {
        switch state {
        case .sessions(_, _, _, let capacity): return capacity
        case .empty(_, let capacity): return capacity
        case .noAccess: return 0
        }
    }

    private var sessionCount: Int {
        if case .sessions(let sessions, _, _, _) = state { return sessions.count }
        return 0
    }
}
