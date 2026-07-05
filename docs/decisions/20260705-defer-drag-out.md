# Defer drag-out export from the popover (v1 sprint)

**Date:** 2026-07-05
**Status:** decided (stakeholder, mid-build)
**Scope:** menu-bar-app cycle (tasks/2026-07-04-menubar-app/)

## Considered

1. Ship drag-out as designed (row = drag source, NSFilePromiseProvider, lazy write at drop).
2. Defer drag-out; export = Dump (WAV to temp + Finder reveal) and Copy (WAV to temp + file
   URL on clipboard).
3. Defer drag-out AND Copy; Dump as the only gesture.

## Chosen

Option 2 — drag-out deferred; Dump + Copy stay.

## Why

Spike SK1 proved drag is the one high-friction mechanism in the popover: SwiftUI's `.onDrag`
cannot carry an `NSFilePromiseProvider` (compile-time), and the AppKit fallback
(`NSViewRepresentable` behind the row) never received mouse events in the stakeholder's live
test — the arrangement needs an inverted NSView-hosts-SwiftUI structure with hit-test routing,
i.e. real engineering risk for a convenience gesture. Dump and Copy deliver the same job
(session → file in hand) with zero spike risk. Copy stays because it is cheap (NSPasteboard
file URL), survived UX review, and is the keyboard/VoiceOver-reachable path now that drag is
gone.

## Limitations

- The "grab it anywhere" gesture (drop into Slack/mail directly) is a two-step now: Copy,
  then paste — or Dump, then drag the revealed file from Finder.
- flows.md F2/hover-actions and design §5 ExportService were written drag-inclusive; both
  carry dated superseding notes pointing here.

## Reversal

Re-add when the two-step grind is actually felt. The implementation path is already
de-risked in writing: SK1's findings (state.md spike log, tmp/spike-popover/) record that
the working arrangement is an NSView container hosting the SwiftUI row via NSHostingView,
drag threshold in mouseDragged, hitTest routing around the button area — start there, not
from `.onDrag`.
