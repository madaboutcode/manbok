import SwiftUI
import AVFoundation
import ManbokCore
import ManbokPlatform

@main
struct ManbokApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var orchestrator: CaptureOrchestrator
    @StateObject private var settings: SettingsStore
    @StateObject private var viewModel: PopoverViewModel

    private let registry: SessionRegistry
    private static let log = AppLog(category: .app)

    init() {
        Diagnostics.install(OSLogOnlyDiagnostics())
        Self.log.notice("app init: starting")
        MigrationService.runIfNeeded()

        let settingsStore = SettingsStore()
        Self.log.notice("app init: buffer preset=\(settingsStore.bufferPreset.rawValue)")
        let capacity = BufferPolicy.capacityBytes(for: settingsStore.bufferPreset)

        let reg: SessionRegistry
        if let (manifest, pcm) = StatePersistenceService.restore() {
            Self.log.notice("app init: restoring checkpoint — \(manifest.sessions.count) sessions, \(pcm.count) bytes PCM")
            reg = SessionRegistry(restoredFrom: manifest, ringData: pcm)
            StatePersistenceService.clear()
            if manifest.ringCapacityBytes != capacity {
                Self.log.notice("app init: preset changed, resizing \(manifest.ringCapacityBytes) → \(capacity)")
                try? reg.resize(to: settingsStore.bufferPreset)
            }
        } else {
            reg = SessionRegistry(ringCapacity: capacity)
        }

        let capture = AVAudioCapture()
        let orch = CaptureOrchestrator(capture: capture, registry: reg)
        let vm = PopoverViewModel(registry: reg, orchestrator: orch)

        self.registry = reg
        _orchestrator = StateObject(wrappedValue: orch)
        _settings = StateObject(wrappedValue: settingsStore)
        _viewModel = StateObject(wrappedValue: vm)

        startIPCServer(registry: reg, orchestrator: orch)
        orch.start()

        appDelegate.saveCheckpoint = {
            Self.performCheckpoint(registry: reg)
        }

        Self.log.notice("app init: complete — ring capacity=\(capacity) bytes, sessions=\(reg.listSessions().count)")
    }

    private static nonisolated func performCheckpoint(registry: SessionRegistry) {
        let checkpointLog = AppLog(category: .app)
        let (manifest, ringData) = registry.checkpoint()
        do {
            try StatePersistenceService.save(manifest: manifest, ringData: ringData)
        } catch {
            checkpointLog.error("checkpoint save failed: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView()
                .environmentObject(orchestrator)
                .environmentObject(settings)
                .environmentObject(viewModel)
        } label: {
            MenuBarIcon(
                anySessionOpen: orchestrator.anySessionOpen,
                micPermission: orchestrator.micPermission
            )
        }
        .menuBarExtraStyle(.window)

        Window("About manbok", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        // Plain Window instead of a Settings scene: this is an LSUIElement app
        // with no app menu, so the scene's menu-item/Cmd+, integration buys
        // nothing — and its window insists on repainting system titlebar
        // chrome over our theme. hiddenTitleBar removes the contested surface.
        Window("Manbok Settings", id: "settings") {
            SettingsView(registry: registry)
                .environmentObject(settings)
                .environmentObject(orchestrator)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
    }

    private func startIPCServer(registry: SessionRegistry, orchestrator: CaptureOrchestrator) {
        let dumpSink = PlatformDumpSink()
        let ipcLog = AppLog(category: .ipc)

        let server = UnixSocketServer { command in
            ipcLog.debug("received \(command.wireLine)")
            let response: IPCResponse
            switch command {
            case .ping:
                response = .pong

            case .status:
                let ring = RingBufferSummary(filledBytes: registry.filledBytes)
                if orchestrator.anySessionOpen {
                    response = .listening(ring: ring)
                } else {
                    response = .watching(ring: ring)
                }

            case .sessions:
                let now = Date()
                let summaries = registry.listSessions().map { s in
                    SessionSummary(
                        id: s.stableId,
                        audioBytes: s.audioBytes,
                        durationSeconds: s.durationSeconds,
                        startedSecondsAgo: now.timeIntervalSince(s.startedAt),
                        endedSecondsAgo: s.endedAt.map { now.timeIntervalSince($0) },
                        isOpen: s.isOpen,
                        appName: s.displayName.isEmpty ? nil : s.displayName
                    )
                }
                response = .sessions(summaries)

            case .stop:
                ipcLog.notice("stop received — saving checkpoint and shutting down")
                Self.performCheckpoint(registry: registry)
                orchestrator.stop()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    exit(0)
                }
                response = .ok

            case .dump(let minutes, let sessionId):
                do {
                    let pcm: Data
                    if let sessionId {
                        guard let data = registry.snapshotForSession(stableId: sessionId),
                              !data.isEmpty else {
                            ipcLog.warning("dump session \(sessionId) not found")
                            response = .error(
                                code: ListenerError.sessionNotFound(sessionId).code,
                                message: "session \(sessionId) not found"
                            )
                            return response
                        }
                        pcm = data
                    } else {
                        let data = registry.snapshotForDump(minutes: minutes)
                        guard !data.isEmpty else {
                            ipcLog.warning("dump failed — ring empty")
                            response = .error(
                                code: ListenerError.emptyBuffer.code,
                                message: "ring buffer is empty"
                            )
                            return response
                        }
                        pcm = data
                    }
                    let wav = WavPCMEncoder.encode(pcm: pcm)
                    let url = dumpSink.nextURL()
                    try dumpSink.write(wav: wav, to: url)
                    ipcLog.info("dump wrote \(wav.count) bytes to \(url.lastPathComponent)")
                    response = .okPath(url)
                } catch {
                    ipcLog.error("dump I/O error: \(error.localizedDescription)")
                    response = .error(code: "dump_io", message: error.localizedDescription)
                }
            }
            return response
        }

        DispatchQueue.global().async {
            do {
                try AppStatePaths.ensureDirectory()
                DaemonProcess.removeStaleSocket()
                ipcLog.info("socket server starting on \(AppStatePaths.socketURL.path)")
                try server.run()
                ipcLog.info("socket server stopped")
            } catch {
                ipcLog.error("socket server failed: \(error.localizedDescription)")
            }
        }
    }
}

struct MenuBarIcon: View {
    let anySessionOpen: Bool
    let micPermission: MicPermissionState

    var body: some View {
        image
    }

    @ViewBuilder
    private var image: some View {
        if micPermission == .denied {
            loadIcon("ear-noaccess", template: false)
        } else if anySessionOpen {
            loadIcon("ear-recording", template: true)
                .foregroundStyle(.red)
        } else {
            loadIcon("ear-watching", template: true)
        }
    }

    @ViewBuilder
    private func loadIcon(_ name: String, template: Bool) -> some View {
        if let img = loadNSImage(name, template: template) {
            Image(nsImage: img)
        } else {
            Image(systemName: "ear")
        }
    }

    private func loadNSImage(_ name: String, template: Bool) -> NSImage? {
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else {
            guard let url2x = bundle.url(forResource: "\(name)@2x", withExtension: "png"),
                  let img2x = NSImage(contentsOf: url2x) else {
                return nil
            }
            img2x.isTemplate = template
            return img2x
        }
        if let url2x = bundle.url(forResource: "\(name)@2x", withExtension: "png"),
           let img2x = NSImage(contentsOf: url2x) {
            img.addRepresentation(img2x.representations[0])
        }
        img.isTemplate = template
        return img
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    private let log = AppLog(category: .app)
    var saveCheckpoint: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        log.notice("delegate: applicationDidFinishLaunching")

        ProcessInfo.processInfo.disableAutomaticTermination("manbok is a long-running audio buffer")
        ProcessInfo.processInfo.disableSuddenTermination()
        log.notice("delegate: auto-termination disabled")

        requestMicPermission()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        log.notice("delegate: saving checkpoint before termination")
        saveCheckpoint?()
        log.notice("delegate: checkpoint saved — terminating")
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        log.info("delegate: reopen requested (hasVisibleWindows=\(flag))")
        return true
    }

    private func requestMicPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        log.notice("delegate: mic authorization status=\(status.rawValue)")
        if status == .notDetermined {
            log.info("delegate: requesting mic access")
            AVCaptureDevice.requestAccess(for: .audio) { [self] granted in
                log.notice("delegate: mic access \(granted ? "granted" : "denied")")
            }
        }
    }

}
