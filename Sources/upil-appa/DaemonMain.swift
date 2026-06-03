import Foundation
import UpilAppaCore
import UpilAppaPlatform

// MARK: - CONTRACT (DaemonMain)
//
// GUARANTEES
// - Ensures `AppStatePaths` directory exists and writes current pid to `appa.pid`.
// - Wires `ListenerService(AVAudioCapture(), PlatformDumpSink())` to `UnixSocketServer`.
// - IPC: PING→PONG, STATUS→LISTENING|STOPPED, DUMP→OK path=<absolute>|ERR, STOP→OK.
// - Starts capture before entering the accept loop.
//
// EXPECTS
// - Invoked only via `upil-appa daemon` after `DaemonProcess.startDaemon` exec.
//
// FAILURE BEHAVIOR
// - Capture or bind errors log and exit non-zero.
//
// DOES NOT
// - Parse CLI flags or launch Audacity (see CommandRouter).

public enum DaemonMain {
    private static let log = AppLog(category: .daemon)
    private static var server: UnixSocketServer?

    public static func runDaemon() {
        do {
            try AppStatePaths.ensureDirectory()
            try DaemonProcess.writeCurrentPID()
            DaemonProcess.removeStaleSocket()

            let service = ListenerService(
                capture: AVAudioCapture(),
                dumpSink: PlatformDumpSink()
            )
            try service.startCapture()
            log.info("daemon listening on \(AppStatePaths.socketURL.path)")

            let socketServer = UnixSocketServer { command in
                handle(command: command, service: service)
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

    private static func handle(command: IPCCommand, service: ListenerService) -> IPCResponse {
        switch command {
        case .ping:
            return .pong
        case .status:
            return service.isListening ? .listening : .stopped
        case .stop:
            service.stopCapture()
            shutdown()
            DispatchQueue.global().async {
                exit(0)
            }
            return .ok
        case .dump(let minutes):
            return dumpResponse(service: service, minutes: minutes)
        }
    }

    private static func shutdown() {
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