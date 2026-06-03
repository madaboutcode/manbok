import Foundation
import UpilAppaCore
import UpilAppaPlatform

// MARK: - CONTRACT (DaemonMain)
//
// GUARANTEES
// - Ensures `AppStatePaths` directory exists and writes current pid to `appa.pid`.
// - Default: opportunistic capture (mic only when default input is in use elsewhere).
// - `--always-on` on daemon argv: continuous capture (legacy behavior).
// - IPC: PING, STATUS→LISTENING|WATCHING|STOPPED, DUMP, STOP.
//
// DOES NOT
// - Parse user-facing CLI flags (see CommandRouter).

public enum DaemonMain {
    private static let log = AppLog(category: .daemon)
    private static var server: UnixSocketServer?
    private static var opportunistic: OpportunisticCaptureController?

    public static func runDaemon() {
        let alwaysOn = CommandLine.arguments.contains("always-on")

        do {
            try AppStatePaths.ensureDirectory()
            try DaemonProcess.writeCurrentPID()
            DaemonProcess.removeStaleSocket()

            let service = ListenerService(
                capture: AVAudioCapture(),
                dumpSink: PlatformDumpSink()
            )

            if alwaysOn {
                try service.startCapture()
                log.info("daemon listening (always-on) on \(AppStatePaths.socketURL.path)")
            } else {
                let controller = OpportunisticCaptureController(service: service)
                controller.start()
                opportunistic = controller
                log.info("daemon listening (opportunistic) on \(AppStatePaths.socketURL.path)")
            }

            let socketServer = UnixSocketServer { command in
                handle(command: command, service: service, alwaysOn: alwaysOn)
            }
            server = socketServer
            try socketServer.run()
        } catch {
            log.error("daemon failed: \(error)")
            shutdown()
            exit(1)
        }
        shutdown()
    }

    private static func handle(
        command: IPCCommand,
        service: ListenerService,
        alwaysOn: Bool
    ) -> IPCResponse {
        switch command {
        case .ping:
            return .pong
        case .status:
            return statusResponse(service: service, alwaysOn: alwaysOn)
        case .stop:
            opportunistic?.stop()
            service.stopCapture()
            shutdown()
            DispatchQueue.global().async { exit(0) }
            return .ok
        case .dump(let minutes):
            return dumpResponse(service: service, minutes: minutes)
        }
    }

    private static func statusResponse(service: ListenerService, alwaysOn: Bool) -> IPCResponse {
        if service.isListening { return .listening }
        if !alwaysOn, opportunistic != nil { return .watching }
        return .stopped
    }

    private static func shutdown() {
        opportunistic?.stop()
        opportunistic = nil
        server?.stop()
        server = nil
        DaemonProcess.reclaimStaleState()
    }

    private static func dumpResponse(service: ListenerService, minutes: Int?) -> IPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var response: IPCResponse = .err("dump failed")

        Task {
            defer { semaphore.signal() }
            do {
                let url = try await service.dump(minutes: minutes)
                response = .okPath(url)
            } catch let error as ListenerError {
                response = .err(error.message)
            } catch {
                response = .err(error.localizedDescription)
            }
        }

        semaphore.wait()
        return response
    }
}