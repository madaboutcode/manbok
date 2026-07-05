import SwiftUI
import AppKit

/// Themes a hosting `NSWindow`'s chrome (titlebar strip, corner fringe,
/// traffic-light appearance) to match the app's dark warm panel background.
///
/// SwiftUI's `.background`/`.tint`/`.environment(\.colorScheme)` only style
/// the *content* view — the titlebar region and window background color are
/// owned by AppKit and must be set directly on the `NSWindow`. Without this,
/// windows built from `PanelBackgroundView` show a clashing standard-gray
/// titlebar strip above the themed content.
///
/// `view.window` is `nil` at `makeNSView` time (the view isn't attached to a
/// window yet), and a `DispatchQueue.main.async` at that point races window
/// attachment — on first open, the window still isn't guaranteed to exist one
/// runloop turn later, so the styling can silently no-op. Instead, a tiny
/// `NSView` subclass hooks `viewDidMoveToWindow`, which AppKit invokes the
/// moment the view is actually attached to its window (`window` is
/// guaranteed non-nil there). `updateNSView` also re-applies whenever the
/// view is already attached, as belt-and-braces for windows that are closed
/// and reopened (e.g. Settings) and reuse the same hosting view. All the
/// styling calls are idempotent, so re-applying on every attach/update is
/// harmless.
struct WindowThemer: NSViewRepresentable {
    func makeNSView(context: Context) -> ThemingView {
        ThemingView()
    }

    func updateNSView(_ nsView: ThemingView, context: Context) {
        if nsView.window != nil {
            ThemingView.style(nsView.window)
        }
    }

    final class ThemingView: NSView {
        private var keyObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
                self.keyObserver = nil
            }
            guard let window else { return }
            Self.style(window)
            // The Settings scene configures its window after content attaches,
            // clobbering styling applied here in whichever order the runloop
            // schedules. Re-apply after that setup settles, and on every key
            // focus (which always follows scene configuration).
            DispatchQueue.main.async { [weak window] in
                Self.style(window)
            }
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                Self.style(window)
            }
        }

        deinit {
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
            }
        }

        static func style(_ window: NSWindow?) {
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(Theme.bgPanelTop)
            window.appearance = NSAppearance(named: .darkAqua)
            window.isMovableByWindowBackground = true
            window.titlebarSeparatorStyle = .none
        }
    }
}

extension View {
    /// Applies `WindowThemer` to the window hosting this view. Attach at the
    /// root of a `Window`/`Settings` scene's content view.
    func windowThemed() -> some View {
        background(WindowThemer())
    }
}
