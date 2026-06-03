import ArgumentParser
import Foundation
import UpilAppaCore
import UpilAppaPlatform

// MARK: - CONTRACT (CommandRouter)
//
// GUARANTEES
// - Maps start|stop|status|dump to IPC or daemon launch.
// - stdout: dump path (one line) or status word; stderr: AppLog diagnostics.
//
// DOES NOT
// - Touch AVAudioEngine directly.

struct CommandRouter: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upil-appa",
        abstract: "Rolling microphone buffer with on-demand WAV export",
        subcommands: [
            StartCommand.self,
            StopCommand.self,
            StatusCommand.self,
            DumpCommand.self,
            DaemonCommand.self,
        ]
    )
}

private let cliLog = AppLog(category: .cli)

struct StartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start")

    func run() throws {
        if DaemonProcess.isRunning() {
            cliLog.info("already listening")
            return
        }

        let executable = CommandLine.arguments[0]
        try DaemonProcess.startDaemon(executablePath: executable)
        cliLog.info("daemon started")
    }
}

struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop")

    func run() throws {
        do {
            let response = try UnixSocketClient.send(command: .stop)
            switch response {
            case .ok:
                cliLog.info("stopped")
            case .err(let message):
                cliLog.error(message)
                throw ExitCode.failure
            default:
                cliLog.error("unexpected response: \(response.line)")
                throw ExitCode.failure
            }
        } catch {
            cliLog.error(connectionMessage(error))
            throw ExitCode.failure
        }
    }
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")

    func run() throws {
        let word: String
        do {
            let response = try UnixSocketClient.send(command: .status)
            switch response {
            case .listening:
                word = "listening"
            case .stopped:
                word = "stopped"
            case .err(let message):
                cliLog.error(message)
                throw ExitCode.failure
            default:
                cliLog.error("unexpected response: \(response.line)")
                throw ExitCode.failure
            }
        } catch {
            cliLog.debug(connectionMessage(error))
            word = "stopped"
        }

        print(word)
    }
}

struct DumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dump")

    @Option(name: .long, help: "Minutes of audio to export (default: all buffered)")
    var minutes: Int?

    func run() throws {
        do {
            let response = try UnixSocketClient.send(command: .dump(minutes: minutes))
            switch response {
            case .okPath(let url):
                print(url.path)
                if AudacityLauncher.open(path: url.path) {
                    cliLog.info("opened in Audacity")
                } else {
                    cliLog.warning("could not open Audacity — open the WAV manually")
                }
            case .err(let message):
                cliLog.error(message)
                throw ExitCode.failure
            default:
                cliLog.error("unexpected response: \(response.line)")
                throw ExitCode.failure
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            cliLog.error(connectionMessage(error))
            throw ExitCode.failure
        }
    }
}

struct DaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        shouldDisplay: false
    )

    func run() throws {
        DaemonMain.runDaemon()
    }
}

private func connectionMessage(_ error: Error) -> String {
    if let socketError = error as? UnixSocketError {
        switch socketError {
        case .syscall(let detail):
            return "cannot connect to daemon (\(detail))"
        case .pathTooLong:
            return "cannot connect to daemon (socket path too long)"
        }
    }
    return "cannot connect to daemon (\(error.localizedDescription))"
}