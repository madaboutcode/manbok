import SwiftUI
import AppKit

/// Offscreen PNG export via SwiftUI's ImageRenderer (macOS 13+) — no window, no
/// NSApplication run loop, no screen-recording permission. `renderAll(to:)` is invoked
/// from the CLI entry point (see Entry.swift) before the SwiftUI App/Scene machinery
/// ever starts.
@MainActor
enum ScreenshotRenderer {
    static func renderAll(to directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let now = Date()

        render(
            PopoverContentView(state: .sessions(
                MockScenario.heroSessions(now: now),
                isRecording: true,
                ringFilledBytes: MockScenario.heroRingFilledBytes,
                ringCapacityBytes: MockScenario.heroRingCapacityBytes
            )),
            fileName: "popover-sessions.png",
            in: dir
        )

        render(
            PopoverContentView(state: .sessions(
                MockScenario.multiDaySessions(now: now),
                isRecording: true,
                ringFilledBytes: MockScenario.heroRingFilledBytes,
                ringCapacityBytes: MockScenario.heroRingCapacityBytes
            )),
            fileName: "popover-multiday.png",
            in: dir
        )

        render(
            PopoverContentView(state: .empty(
                ringFilledBytes: 0,
                ringCapacityBytes: MockScenario.heroRingCapacityBytes
            )),
            fileName: "popover-empty.png",
            in: dir
        )

        render(
            PopoverContentView(state: .noAccess),
            fileName: "popover-noaccess.png",
            in: dir
        )

        print("Screenshots written to \(dir.path)")
    }

    /// Wraps the popover content in the same PanelContainer used by the interactive
    /// vibe-check window (rounded corners + shadow), since the raw SwiftUI view has no
    /// chrome of its own — that's supplied by the real MenuBarExtra window at runtime.
    private static func render<V: View>(_ view: V, fileName: String, in dir: URL) {
        let wrapped = PanelContainer { view }
            .padding(20)
            .background(Theme.bgRoom)

        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2.0

        guard let nsImage = renderer.nsImage else {
            print("FAILED to render \(fileName): renderer.nsImage was nil")
            return
        }
        guard let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("FAILED to encode \(fileName)")
            return
        }

        let url = dir.appendingPathComponent(fileName)
        do {
            try png.write(to: url)
            print("Wrote \(fileName): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) px")
        } catch {
            print("FAILED to write \(fileName): \(error)")
        }
    }
}
