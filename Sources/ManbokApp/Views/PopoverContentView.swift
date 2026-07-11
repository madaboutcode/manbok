import SwiftUI
import ManbokPlatform

struct PopoverContentView: View {
    @EnvironmentObject private var lifecycle: SessionLifecycleController
    @EnvironmentObject private var viewModel: PopoverViewModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            // The session list starts with a pinned day header whose rule already
            // separates it from the panel header — a divider here would double up.
            if !showsSessionList {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            content
            Rectangle().fill(Theme.line).frame(height: 1)
            FooterView()
        }
        .frame(width: 320)
        .background(PanelBackgroundView().ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }

    @ViewBuilder
    private var content: some View {
        if lifecycle.micPermission == .denied {
            PermissionDeniedView()
        } else if viewModel.sessions.isEmpty {
            EmptyStateView()
        } else {
            SessionListView()
        }
    }

    private var showsSessionList: Bool {
        lifecycle.micPermission != .denied && !viewModel.sessions.isEmpty
    }
}
