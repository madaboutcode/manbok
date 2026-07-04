import Darwin
import Foundation
import ManbokPlatform

// MARK: - CONTRACT (DaemonMain)
//
// GUARANTEES
// - Bootstraps diagnostics + activity from DaemonPresentation, then runs DaemonSession.
//
// DOES NOT
// - Parse user-facing CLI flags (see CommandRouter).

public enum DaemonMain {
    public static func runDaemon(
        presentation: DaemonPresentation,
        alwaysOn: Bool? = nil
    ) {
        signal(SIGPIPE, SIG_IGN)
        let alwaysOn = alwaysOn ?? CommandLine.arguments.contains("always-on")
        DaemonRuntimeEnvironment.bootstrap(presentation: presentation)
        DaemonSession(presentation: presentation, alwaysOn: alwaysOn).run()
    }
}