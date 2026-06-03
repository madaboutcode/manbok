import Foundation

@main
struct UpilAppaMain {
    static func main() {
        if CommandLine.arguments.contains("daemon") {
            DaemonMain.runDaemon()
            return
        }

        CommandRouter.main()
    }
}