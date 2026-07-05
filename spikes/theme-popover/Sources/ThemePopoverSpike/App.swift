import SwiftUI

@main
struct ThemePopoverSpikeApp: App {
    var body: some Scene {
        WindowGroup("Vibe Check") {
            VibeCheckView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("manbok", systemImage: "ear") {
            MenuBarProbeView()
        }
        .menuBarExtraStyle(.window)
    }
}
