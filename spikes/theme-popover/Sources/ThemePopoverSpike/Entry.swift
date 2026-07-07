import SwiftUI

/// `@main` lives here instead of on `ThemePopoverSpikeApp` so we can intercept a
/// screenshot-export request before SwiftUI's App/Scene machinery starts an app run
/// loop. `ImageRenderer` doesn't need a running NSApplication, so this path renders
/// PNGs and exits — no window ever opens.
///
/// Usage: swift run ThemePopoverSpike --render-screenshots /absolute/output/dir
@main
enum ThemePopoverEntry {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let flagIndex = args.firstIndex(of: "--render-screenshots") {
            let outDir = args.indices.contains(flagIndex + 1)
                ? args[flagIndex + 1]
                : "tmp/screenshots"
            ScreenshotRenderer.renderAll(to: outDir)
            exit(0)
        }
        ThemePopoverSpikeApp.main()
    }
}
