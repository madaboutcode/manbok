import Foundation
import UpilAppaPlatform

@main
struct UpilAppaMain {
    static func main() {
        if CommandLine.arguments.contains("daemon") {
            DaemonMain.runDaemon(presentation: .detached)
            return
        }

        Diagnostics.install(OSLogAndStderrDiagnostics())
        CommandRouter.main()
    }
}