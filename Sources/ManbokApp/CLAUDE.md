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
