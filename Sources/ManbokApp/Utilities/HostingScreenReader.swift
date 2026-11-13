import SwiftUI
import AppKit

/// Reports the usable height of the screen hosting the view this is attached to,
/// and re-reports when that window changes displays or the display arrangement
/// changes.
///
/// The popover sizes itself from the display whose menu bar was clicked.
/// `NSScreen.main` is the screen of the *key* window — nil, or the wrong display,
/// for a `MenuBarExtra`, which puts its status item in every menu bar. So the
/// popover asks its own window here, and the pointer is only consulted while the
/// window does not exist yet (a menu-bar item can be pressed with the pointer on
/// another display, hence the window wins).
///
/// What crosses into SwiftUI is the `visibleFrame` height value, not the
/// `NSScreen` object: display parameters (Dock, resolution, menu-bar size) can
/// change on the *same* screen instance, so a reference would hide the change,
/// and identical heights on a different instance would needlessly re-lay out the
/// popover.
struct HostingScreenReader: NSViewRepresentable {
    /// Called on the main thread with the hosting screen's usable height (menu bar
    /// and Dock excluded); nil before the view has a window and no screen can be
    /// inferred.
    let onUsableHeightChange: (CGFloat?) -> Void

    func makeNSView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.onUsableHeightChange = onUsableHeightChange
        return view
    }

    func updateNSView(_ nsView: ReporterView, context: Context) {
        nsView.onUsableHeightChange = onUsableHeightChange
        nsView.scheduleReport()
    }

    /// Usable height of a screen, or nil when unknown.
    static func usableHeight(of screen: NSScreen?) -> CGFloat? {
        screen?.visibleFrame.height
    }

    /// Best guess for a view with no window yet: the display under the pointer
    /// (a menu-bar click happens on the display whose item was clicked).
    static func usableHeightUnderPointer() -> CGFloat? {
        let location = NSEvent.mouseLocation
        return usableHeight(of: NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main)
    }

    /// `view.window` is nil at `makeNSView` time — the popover's panel is created
    /// when the popover first opens — so the first trustworthy report comes from
    /// `viewDidMoveToWindow`. The window is then reused across opens, so the
    /// per-open refresh rides on `didBecomeKey` (plus screen-move and
    /// display-arrangement notifications) rather than on view lifetime.
    final class ReporterView: NSView {
        var onUsableHeightChange: ((CGFloat?) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var reportScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let window else { return scheduleReport() }
            let center = NotificationCenter.default
            observers = [
                NSWindow.didChangeScreenNotification,
                NSWindow.didBecomeKeyNotification,
            ].map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.scheduleReport()
                }
            }
            observers.append(center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleReport()
            })
            scheduleReport()
        }

        deinit { removeObservers() }

        /// Reports on the next runloop turn: the closure lands in SwiftUI state,
        /// and AppKit calls in here mid-layout (window attach, key focus).
        func scheduleReport() {
            guard !reportScheduled else { return }
            reportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                reportScheduled = false
                onUsableHeightChange?(HostingScreenReader.usableHeight(
                    of: window?.screen ?? NSScreen.screens.first {
                        $0.frame.contains(NSEvent.mouseLocation)
                    } ?? NSScreen.main
                ))
            }
        }

        private func removeObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
    }
}
