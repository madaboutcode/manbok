# ManbokApp

SwiftUI menu bar app target. No ArgumentParser, no direct AVFoundation.

## Jumpstart

### What This Module Owns

App entry point, MenuBarExtra popover, Settings window, PopoverViewModel, icon state management, IPC server wiring, single-instance enforcement (`SingleInstance.claim()` at the top of `ManbokApp.init()`), first-launch mic permission.

### Layout

| Folder | Files |
|--------|-------|
| root | `ManbokApp.swift` — @main App, MenuBarIcon, AppDelegate |
| `ViewModels/` | `PopoverViewModel` — polls SessionRegistry, export wrappers |
| `Views/` | `PopoverContentView`, `HeaderView`, `SessionListView`, `SessionRowView`, `WaveformView`, `EmptyStateView`, `PermissionDeniedView`, `FooterView`, `SettingsView`, `Theme` — Listening Post tokens + TapeGaugeView (design: the "Listening Post" amber-on-dark theme) |

### Key Types

- `PopoverViewModel` — @MainActor ObservableObject, 1Hz polling when popover visible
- `MenuBarIcon` — dynamic icon from bundle resources (watching/recording/noaccess)
- `AppDelegate` — mic permission request

## Constraints

- No ArgumentParser (that's the CLI target only)
- No direct AVFoundation imports — use SessionLifecycleController from ManbokPlatform
- Views observe SessionLifecycleController (environmentObject) for icon/badge state
- Settings window calls SessionRegistry.resize() directly (no IPC verb)
- Settings "Apps" section: rows from `SessionLifecycleController.holdingNow` + `SettingsStore.excludedApps` + registry sessions (`ExclusionRows.build`); the Record toggle edits `excludedApps`, and `ManbokApp` forwards changes to `setExcludedGroups`. Built and source-read only; not viewed running.
- Silent-mic alarm: `SilenceAlarmMonitor.status` drives the `mic.slash` menu-bar icon (above recording, below no-access) and one line under the popover header; Settings "Silent mic" section binds `SettingsStore.silenceAlarmEnabled`/`silenceAlarmSeconds`. Built and source-read only; not viewed running.
- Popover width is fixed at 320 pt. The session-list state pins the window height via
  `PopoverSizing.totalHeight` off the *hosting* screen's `visibleFrame` (`NSScreen.main` is
  the wrong display for a `MenuBarExtra`), and `SessionListView` is the only flexible zone.
  Keep that screen information as a height **value**: the Dock or resolution can change on the
  same `NSScreen` instance, and an unchanged height must not re-lay out the popover. Never
  reintroduce a bare `maxHeight` on that `ScrollView`: a `LazyVStack` has no stable ideal
  height, so the window collapses to ~1 row.
