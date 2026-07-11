import SwiftUI

struct ThemePopoverSpikeApp: App {
    var body: some Scene {
        WindowGroup("Vibe Check") {
            VibeCheckView()
                .frame(minWidth: 1500, minHeight: 560)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("manbok", systemImage: "ear") {
            PopoverContentView(state: .sessions(
                MockScenario.heroSessions(now: Date()),
                isRecording: true,
                ringFilledBytes: MockScenario.heroRingFilledBytes,
                ringCapacityBytes: MockScenario.heroRingCapacityBytes
            ))
        }
        .menuBarExtraStyle(.window)
    }
}
