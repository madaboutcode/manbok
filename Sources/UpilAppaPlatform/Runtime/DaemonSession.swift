import Foundation
import UpilAppaCore

// MARK: - CONTRACT (DaemonSession)
//
// GUARANTEES
// - Owns listener lifecycle, opportunistic vs always-on, IPC server, activity presenter.
// - Presentation chosen at construction; no foreground checks inside capture code.
//
// DOES NOT
// - Parse CLI flags.

public final class DaemonSession {
    private let presentation: DaemonPresentation
    private let alwaysOn: Bool
    private let log = AppLog(category: .daemon)

    private var server: UnixSocketServer?
    private var opportunistic: OpportunisticCaptureController?
    private var activityPresenter: ActivityPresenting?

    public init(presentation: DaemonPresentation, alwaysOn: Bool) {
        self.presentation = presentation
        self.alwaysOn = alwaysOn
    }

    public func run() {
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

            let presenter = DaemonRuntimeEnvironment.makeActivityPresenter(
                presentation: presentation,
                snapshot: { service.currentActivity },
                mode: { [weak self] in self?.meterMode(service: service) ?? .watching },
                isCapturing: { service.isListening },
                ringFilledBytes: { service.ringFilledBytes }
            )
            presenter.start()
            activityPresenter = presenter

            let socketServer = UnixSocketServer { [weak self] command in
                self?.handle(command: command, service: service) ?? .err("daemon unavailable")
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

    private func meterMode(service: ListenerService) -> TerminalCaptureMeter.Mode {
        if alwaysOn {
            return service.isListening ? .listening : .watching
        }
        if service.isListening { return .capturing }
        if opportunistic?.currentPhase == .capturing { return .capturing }
        return .watching
    }

    private func handle(command: IPCCommand, service: ListenerService) -> IPCResponse {
        switch command {
        case .ping:
            return .pong
        case .status:
            return statusResponse(service: service)
        case .sessions:
            return .sessions(service.listSessions())
        case .stop:
            opportunistic?.stop()
            service.stopCapture()
            shutdown()
            DispatchQueue.global().async { exit(0) }
            return .ok
        case .dump(let minutes, let sessionId):
            return dumpResponse(service: service, minutes: minutes, sessionId: sessionId)
        }
    }

    private func statusResponse(service: ListenerService) -> IPCResponse {
        let ring = RingBufferSummary(filledBytes: service.ringFilledBytes)
        if service.isListening { return .listening(ring: ring) }
        if !alwaysOn, opportunistic != nil { return .watching(ring: ring) }
        return .stopped(ring: ring)
    }

    private func shutdown() {
        activityPresenter?.stop()
        activityPresenter = nil
        opportunistic?.stop()
        opportunistic = nil
        server?.stop()
        server = nil
        DaemonProcess.reclaimStaleState()
    }

    private func dumpErrorMessage(_ error: ListenerError, service: ListenerService) -> String {
        guard error == .emptyBuffer else { return error.message }
        if service.isListening { return "\(error.message) (listening — no PCM received yet)" }
        if service.ringFilledBytes > 0 {
            return "\(error.message) (unexpected — ring has \(service.ringFilledBytes) bytes; file a bug)"
        }
        if !alwaysOn, opportunistic != nil {
            return "\(error.message) (watching — capture first, or ring was never filled)"
        }
        return "\(error.message) (stopped)"
    }

    private func dumpResponse(
        service: ListenerService,
        minutes: Int?,
        sessionId: Int?
    ) -> IPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var response: IPCResponse = .err("dump failed")

        Task {
            defer { semaphore.signal() }
            do {
                let url: URL
                if let sessionId {
                    url = try await service.dump(sessionId: sessionId)
                } else {
                    url = try await service.dump(minutes: minutes)
                }
                response = .okPath(url)
            } catch let error as ListenerError {
                response = .err(dumpErrorMessage(error, service: service))
            } catch {
                response = .err(error.localizedDescription)
            }
        }

        semaphore.wait()
        return response
    }
}