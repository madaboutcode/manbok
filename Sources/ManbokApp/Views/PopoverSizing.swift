import CoreGraphics

/// Height rule for the menu-bar popover while the session list is showing.
///
/// A `MenuBarExtra(.window)` popover sizes its window to the hosting view's ideal
/// height, and a `ScrollView` over a `LazyVStack` has no stable ideal height — it
/// collapses to roughly one realized row, which is why the popover used to open
/// barely taller than a single session (~1.3 rows). So the root view pins itself
/// to `totalHeight` and the session list is its only flexible zone: the header and
/// footer keep their real laid-out heights and the list absorbs what is left.
/// That accounts for the chrome without a constant that would silently drift the
/// day a padding or label in `HeaderView`/`FooterView` changes.
///
/// CONTRACT
///   `totalHeight(visibleFrameHeight:)`
///   GUARANTEES
///     - Scales with the screen: `screenFraction ×` the usable height, at or above
///       `minTotal` and never above `maxTotal` — as long as the screen itself has
///       room for `minTotal`.
///     - The available-space clamp wins on short screens: the result never exceeds
///       `visibleFrameHeight - bottomInset`. Since `minTotal + bottomInset` is
///       376 pt, screens with less usable height than that get a popup below
///       `minTotal` (300 pt of usable height → 284 pt popup); the floor is not an
///       override.
///     - Non-decreasing in `visibleFrameHeight`; never negative.
///   FAILURE BEHAVIOR
///     - Short of `bottomInset` above the fixed header+footer chrome (~132 pt), i.e.
///       below ~148 pt of usable height, there is no room left for the list and the
///       footer would be clipped — shorter than any display that can show a menu bar
///       to click.
enum PopoverSizing {
    /// Share of the active screen's usable height the open popover may occupy.
    static let screenFraction: CGFloat = 0.66
    /// Smallest popup worth opening: the size the rule settles at where the
    /// fraction alone would be cramped (≲ 545 pt of usable height).
    static let minTotal: CGFloat = 360
    /// Largest popup: past this the list scrolls comfortably, and on tall displays
    /// the popover stops growing rather than swallowing the screen.
    static let maxTotal: CGFloat = 680
    /// Gap kept clear below the popover (it opens flush under the menu bar).
    static let bottomInset: CGFloat = 16

    /// Total popup height for the session-list state on a display whose usable
    /// (menu-bar- and Dock-excluded) height is `visibleFrameHeight`.
    static func totalHeight(visibleFrameHeight: CGFloat) -> CGFloat {
        let target = min(max(screenFraction * visibleFrameHeight, minTotal), maxTotal)
        return min(target, max(0, visibleFrameHeight - bottomInset))
    }
}
