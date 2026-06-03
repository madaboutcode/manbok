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

    @Flag(name: .long, help: "Keep microphone open continuously (legacy; default is opportunistic)")
    var alwaysOn = false

    @Flag(name: .long, help: "Run daemon in this terminal (logs on stderr); do not detach")
    var foreground = false

    func run() throws {
        if foreground {
            if DaemonProcess.isRunning() {
                cliLog.error("daemon already running — stop it first")
                throw ExitCode.failure
            }
            cliLog.info("daemon in foreground — meter on TTY; logs in Console (ai.upil.appa)")
            DaemonMain.runDaemon(presentation: .foregroundMeter, alwaysOn: alwaysOn)
            return
        }

        if DaemonProcess.isRunning() {
            if let response = try? UnixSocketClient.send(command: .status) {
                switch response {
                case .listening, .watching:
                    cliLog.info("already running")
                    return
                default:
                    break
                }
            }
            cliLog.info("replacing stale daemon")
            try terminateRunningDaemon()
        }

        let executable = CommandLine.arguments[0]
        let args = alwaysOn ? ["always-on"] : []
        try DaemonProcess.startDaemon(executablePath: executable, daemonArguments: args)
        if alwaysOn {
            cliLog.info("daemon started (always-on)")
        } else {
            cliLog.info("daemon started (opportunistic — captures when another app uses the mic)")
        }
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
        do {
            let response = try UnixSocketClient.send(command: .status)
            switch response {
            case .listening(let ring):
                print(statusLine(phase: "listening", ring: ring))
            case .watching(let ring):
                print(statusLine(phase: "watching", ring: ring))
            case .stopped(let ring):
                print(statusLine(phase: "stopped", ring: ring))
            case .err(let message):
                cliLog.error(message)
                throw ExitCode.failure
            default:
                cliLog.error("unexpected response: \(response.line)")
                throw ExitCode.failure
            }
        } catch {
            cliLog.debug(connectionMessage(error))
            print(statusLine(phase: "stopped", ring: RingBufferSummary(filledBytes: 0)))
        }
    }
}

private func statusLine(phase: String, ring: RingBufferSummary) -> String {
    "\(phase) \(ring.displaySuffix)"
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
                explainDumpFailure(message)
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
        abstract: "Run the listener in the foreground (for debugging)"
    )

    @Flag(name: .long, help: "Continuous capture (legacy)")
    var alwaysOn = false

    func run() throws {
        if DaemonProcess.isRunning() {
            cliLog.error("daemon already running — stop it first")
            throw ExitCode.failure
        }
        DaemonMain.runDaemon(presentation: .foregroundMeter, alwaysOn: alwaysOn)
    }
}

private func terminateRunningDaemon() throws {
    _ = try? UnixSocketClient.send(command: .stop)
    DaemonProcess.reclaimStaleState()
    usleep(200_000)
}

private func explainDumpFailure(_ message: String) {
    guard message.hasPrefix(ListenerError.emptyBuffer.message) else { return }
    if message.contains("watching") || message.contains("stopped") || message.contains("listening") {
        return
    }
    guard let status = try? UnixSocketClient.send(command: .status) else { return }
    switch status {
    case .watching:
        cliLog.error(
            "daemon is watching — start recording in Zoom/Voice Memos, "
                + "wait for REC on the meter, then dump from another terminal"
        )
    case .listening:
        cliLog.error(
            "daemon is listening but ring is empty — speak into the mic; check Microphone privacy"
        )
    case .stopped:
        cliLog.error("daemon is stopped — run make start-fg or make start")
    default:
        break
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