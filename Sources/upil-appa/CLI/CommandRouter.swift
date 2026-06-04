import ArgumentParser
import Foundation
import UpilAppaCore
import UpilAppaPlatform

// MARK: - CONTRACT (CommandRouter)
//
// GUARANTEES
// - Maps authorize|start|stop|status|dump|sessions to IPC or daemon launch.
// - `dump` accepts session targets: id, `last`, `last-N`, or `--list`.
// - stdout: dump path (one line) or status word; stderr: AppLog diagnostics.
//
// DOES NOT
// - Touch AVAudioEngine directly.

struct CommandRouter: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upil-appa",
        abstract: "Rolling microphone buffer with on-demand WAV export",
        version: appVersion,
        subcommands: [
            AuthorizeCommand.self,
            StartCommand.self,
            StopCommand.self,
            StatusCommand.self,
            SessionsCommand.self,
            DumpCommand.self,
            DaemonCommand.self,
        ]
    )
}

private let cliLog = AppLog(category: .cli)

struct AuthorizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "authorize",
        abstract: "Request microphone access for this binary (run once from Terminal before background start)"
    )

    func run() throws {
        switch MicrophoneAuthorization.currentStatus() {
        case .authorized:
            print("authorized")
            cliLog.info("microphone already authorized")
            return
        case .denied, .restricted:
            print("denied")
            cliLog.error("microphone access denied — \(MicrophoneAuthorization.settingsHint)")
            throw ExitCode.failure
        case .notDetermined:
            cliLog.info("approve the microphone dialog if macOS shows it")
        }

        guard MicrophoneAuthorization.ensureAuthorized() else {
            print("denied")
            cliLog.error("microphone access denied — \(MicrophoneAuthorization.settingsHint)")
            throw ExitCode.failure
        }
        print("authorized")
        cliLog.info("microphone access granted")
    }
}

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

        guard MicrophoneAuthorization.ensureAuthorized() else {
            cliLog.error("microphone access denied — \(MicrophoneAuthorization.settingsHint)")
            throw ExitCode.failure
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

struct SessionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "List recorded sessions (same as `dump --list`)"
    )

    func run() throws {
        try printSessionList()
    }
}

struct DumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump",
        abstract: "Export WAV — default: newest session; `all` = full ring"
    )

    @Flag(name: .long, help: "List recorded sessions (ids for `dump 1`, `dump -1`, …)")
    var list = false

    @Option(name: .long, help: "Last N minutes of the ring (not a session selector)")
    var minutes: Int?

    @Argument(help: "Omit/`last` = newest; `-1` = prior; `all` = ring; or id `1`")
    var target: String?

    func run() throws {
        if list {
            try printSessionList()
            return
        }

        if minutes != nil, let target, !target.isEmpty {
            cliLog.error("use either a target or --minutes, not both")
            throw ExitCode.failure
        }

        let sessionId: Int?
        if let target, !target.isEmpty {
            if target.lowercased() == "all" {
                sessionId = nil
            } else {
                sessionId = try resolveDumpSessionTarget(target)
            }
        } else if minutes != nil {
            sessionId = nil
        } else {
            sessionId = try resolveDumpSessionTarget("last")
        }

        try performDump(minutes: minutes, sessionId: sessionId)
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

private func fetchSessions() throws -> [SessionSummary] {
    let response = try UnixSocketClient.send(command: .sessions)
    switch response {
    case .sessions(let list):
        return list
    case .err(let message):
        cliLog.error(message)
        throw ExitCode.failure
    default:
        cliLog.error("unexpected response: \(response.line)")
        throw ExitCode.failure
    }
}

private func printSessionList() throws {
    let list = try fetchSessions()
    if list.isEmpty {
        print("no sessions (record in another app, or ring empty)")
        return
    }
    print("  #      dur  ended          started")
    for summary in list {
        print(summary.displayLine())
    }
}

private func resolveDumpSessionTarget(_ text: String) throws -> Int {
    let selector: DumpSessionSelector
    switch DumpSessionSelectorParser.parse(text) {
    case .success(let parsed):
        selector = parsed
    case .failure(.invalidSyntax(let raw)):
        cliLog.error("unknown session \(raw) — use `last`, `-1` (prior), `1`, or `all`; see `upil-appa dump --list`")
        throw ExitCode.failure
    case .failure(.noSessions), .failure(.unknownSession), .failure(.offsetOutOfRange):
        throw ExitCode.failure
    }

    let sessions = try fetchSessions()
    switch DumpSessionSelectorParser.resolve(selector, in: sessions) {
    case .success(let id):
        return id
    case .failure(.noSessions):
        cliLog.error("no sessions — record in another app first")
        throw ExitCode.failure
    case .failure(.unknownSession(let id)):
        cliLog.error("no session #\(id) — run `upil-appa dump --list`")
        throw ExitCode.failure
    case .failure(.offsetOutOfRange(let offset, let count)):
        cliLog.error("only \(count) session\(count == 1 ? "" : "s") — cannot go back \(offset)")
        throw ExitCode.failure
    case .failure(.invalidSyntax):
        throw ExitCode.failure
    }
}

private func performDump(minutes: Int?, sessionId: Int?) throws {
    do {
        let response = try UnixSocketClient.send(command: .dump(minutes: minutes, sessionId: sessionId))
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