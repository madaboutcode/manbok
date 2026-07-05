import ArgumentParser
import Foundation
import ManbokCore
import ManbokPlatform

// MARK: - CONTRACT (CommandRouter)
//
// GUARANTEES
// - Maps authorize|start|stop|status|dump|sessions to IPC or app launch.
// - `start` opens Manbok.app via `open -a Manbok` (no posix_spawn daemon).
// - `start --foreground` runs the old in-process daemon (debug only).
// - `dump` accepts session targets: id, `last`, `last-N`, or `--list`.
// - stdout: dump path (one line) or status word; stderr: AppLog diagnostics.
// - Connection failure → "manbok isn't running" hint (overview.md R9).
//
// DOES NOT
// - Touch AVAudioEngine directly.

struct CommandRouter: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manbok",
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

    @Flag(name: .long, help: "Run in this terminal (debug only); do not launch the app")
    var foreground = false

    @Flag(name: .long, help: "Keep microphone open continuously (debug/foreground only)")
    var alwaysOn = false

    func run() throws {
        if foreground {
            if DaemonProcess.isRunning() {
                cliLog.error("daemon already running — stop it first")
                throw ExitCode.failure
            }
            cliLog.info("daemon in foreground — meter on TTY; logs in Console (ai.manbok.app)")
            DaemonMain.runDaemon(presentation: .foregroundMeter, alwaysOn: alwaysOn)
            return
        }

        if let response = try? UnixSocketClient.send(command: .ping), case .pong = response {
            print("manbok is already running")
            return
        }

        warnIfLaunchAgentExists()
        launchApp()
    }

    private func launchApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Manbok"]
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                cliLog.info("manbok.app launched")
            } else {
                cliLog.error("manbok isn't running — open Manbok.app or run 'make install-app'")
            }
        } catch {
            cliLog.error("manbok isn't running — open Manbok.app or run 'make install-app'")
        }
    }

    private func warnIfLaunchAgentExists() {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.manbok.app.plist").path
        if FileManager.default.fileExists(atPath: plistPath) {
            cliLog.info("migrating from LaunchAgent — the app will remove it on launch")
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
            case .error(_, let message):
                cliLog.error(message)
                throw ExitCode.failure
            default:
                cliLog.error("unexpected response: \(response.jsonLine)")
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
            case .error(_, let message):
                cliLog.error(message)
                throw ExitCode.failure
            default:
                cliLog.error("unexpected response: \(response.jsonLine)")
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

        let sessionId: UInt64?
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
    case .error(_, let message):
        cliLog.error(message)
        throw ExitCode.failure
    default:
        cliLog.error("unexpected response: \(response.jsonLine)")
        throw ExitCode.failure
    }
}

private func printSessionList() throws {
    let list = try fetchSessions()
    print(SessionSummary.table(list))
}

private func resolveDumpSessionTarget(_ text: String) throws -> UInt64 {
    let selector: DumpSessionSelector
    switch DumpSessionSelectorParser.parse(text) {
    case .success(let parsed):
        selector = parsed
    case .failure(.invalidSyntax(let raw)):
        cliLog.error("unknown session \(raw) — use `last`, `-1` (prior), `1`, or `all`; see `manbok dump --list`")
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
        cliLog.error("no session #\(id) — run `manbok dump --list`")
        throw ExitCode.failure
    case .failure(.offsetOutOfRange(let offset, let count)):
        cliLog.error("only \(count) session\(count == 1 ? "" : "s") — cannot go back \(offset)")
        throw ExitCode.failure
    case .failure(.invalidSyntax):
        throw ExitCode.failure
    }
}

private func performDump(minutes: Int?, sessionId: UInt64?) throws {
    do {
        let response = try UnixSocketClient.send(command: .dump(minutes: minutes, sessionId: sessionId))
        switch response {
        case .okPath(let url):
            print(url.path)
        case .error(let code, let message):
            cliLog.error(message)
            explainDumpFailure(code: code, message: message)
            throw ExitCode.failure
        default:
            cliLog.error("unexpected response: \(response.jsonLine)")
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

private func explainDumpFailure(code: String, message: String) {
    guard code == "empty_buffer" else { return }
    if message.contains("watching") || message.contains("stopped") || message.contains("listening") {
        return
    }
    guard let status = try? UnixSocketClient.send(command: .status) else { return }
    switch status {
    case .watching:
        cliLog.error(
            "watching — start recording in another app (Zoom, Voice Memos, …), then dump"
        )
    case .listening:
        cliLog.error(
            "listening but ring is empty — speak into the mic; check Microphone privacy"
        )
    case .stopped:
        cliLog.error("manbok isn't running — run 'manbok start' or open Manbok.app")
    default:
        break
    }
}

private func connectionMessage(_ error: Error) -> String {
    if let socketError = error as? UnixSocketError {
        switch socketError {
        case .syscall:
            return "manbok isn't running — run 'manbok start' or open Manbok.app"
        case .pathTooLong:
            return "cannot connect (socket path too long)"
        }
    }
    return "manbok isn't running — run 'manbok start' or open Manbok.app"
}