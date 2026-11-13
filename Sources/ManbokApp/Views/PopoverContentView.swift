import SwiftUI
import ManbokPlatform

struct PopoverContentView: View {
    @EnvironmentObject private var lifecycle: SessionLifecycleController
    @EnvironmentObject private var viewModel: PopoverViewModel
    /// Usable height (menu bar and Dock excluded) of the screen hosting the popover;
    /// drives the session-list height. Stored as a value, not as an `NSScreen`: the
    /// Dock or resolution can change on the same screen object, and a height that
    /// did not change must not re-lay out the popover.
    @State private var hostingUsableHeight: CGFloat?

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
        .frame(width: 320, height: sessionListHeight)
        .background(PanelBackgroundView().ignoresSafeArea())
        .background(HostingScreenReader { height in
            if height != hostingUsableHeight { hostingUsableHeight = height }
        })
        .environment(\.colorScheme, .dark)
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }

    /// Explicit popup height for the session-list state: without a definite height
    /// the window collapses to the `LazyVStack`'s lazy ideal height (~1 row). The
    /// header/footer keep their laid-out heights and `SessionListView` absorbs the
    /// rest — see `PopoverSizing` for the rule. Empty and permission states stay
    /// `nil` so they keep their compact natural height.
    private var sessionListHeight: CGFloat? {
        guard showsSessionList else { return nil }
        guard let usableHeight = hostingUsableHeight ?? HostingScreenReader.usableHeightUnderPointer() else {
            return nil
        }
        return PopoverSizing.totalHeight(visibleFrameHeight: usableHeight)
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
