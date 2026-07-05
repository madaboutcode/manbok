import SwiftUI
import ManbokPlatform

struct PopoverContentView: View {
    @EnvironmentObject private var orchestrator: CaptureOrchestrator
    @EnvironmentObject private var viewModel: PopoverViewModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Rectangle().fill(Theme.line).frame(height: 1)
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
        if orchestrator.micPermission == .denied {
            PermissionDeniedView()
        } else if viewModel.sessions.isEmpty {
            EmptyStateView()
        } else {
            SessionListView()
        }
    }
}
