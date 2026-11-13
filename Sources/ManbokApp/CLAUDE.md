# ManbokApp

SwiftUI menu bar app target. No ArgumentParser, no direct AVFoundation.

## Jumpstart

### What This Module Owns

App entry point, MenuBarExtra popover, Settings window, PopoverViewModel, icon state management, IPC server wiring, single-instance enforcement, first-launch mic permission.

### Layout

| Folder | Files |
|--------|-------|
| root | `ManbokApp.swift` — @main App, MenuBarIcon, AppDelegate |
| `ViewModels/` | `PopoverViewModel` — polls SessionRegistry, export wrappers |
| `Views/` | `PopoverContentView`, `HeaderView`, `SessionListView`, `SessionRowView`, `WaveformView`, `EmptyStateView`, `PermissionDeniedView`, `FooterView`, `SettingsView`, `Theme` — Listening Post tokens + TapeGaugeView (design: the "Listening Post" amber-on-dark theme) |

### Key Types

- `PopoverViewModel` — @MainActor ObservableObject, 1Hz polling when popover visible
- `MenuBarIcon` — dynamic icon from bundle resources (watching/recording/noaccess)
- `AppDelegate` — mic permission request, single-instance check

## Constraints

- No ArgumentParser (that's the CLI target only)
- No direct AVFoundation imports — use SessionLifecycleController from ManbokPlatform
- Views observe SessionLifecycleController (environmentObject) for icon/badge state
- Settings window calls SessionRegistry.resize() directly (no IPC verb)
- Popover width is fixed at 320 pt. The session-list state pins the window height via
  `PopoverSizing.totalHeight` off the *hosting* screen's `visibleFrame` (`NSScreen.main` is
  the wrong display for a `MenuBarExtra`), and `SessionListView` is the only flexible zone.
  Keep that screen information as a height **value**: the Dock or resolution can change on the
  same `NSScreen` instance, and an unchanged height must not re-lay out the popover. Never
  reintroduce a bare `maxHeight` on that `ScrollView`: a `LazyVStack` has no stable ideal
  height, so the window collapses to ~1 row.
