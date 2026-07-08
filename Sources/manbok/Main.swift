import Foundation
import ManbokPlatform

@main
struct ManbokMain {
    static func main() {
        Diagnostics.install(OSLogAndStderrDiagnostics())
        CommandRouter.main()
    }
}