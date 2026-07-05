import Foundation
import ManbokCore
import ManbokPlatform
import SwiftUI

// MARK: - CONTRACT: PopoverViewModel
//
// GUARANTEES:
// - Bridges SessionRegistry + CaptureOrchestrator to SwiftUI popover views.
// - Polls the registry at ~1 Hz ONLY between startPolling() and stopPolling() — no polling
//   while the popover is not visible.
// - refreshSessions() updates sessions, ringFilled, ringCapacity from the registry;
//   all @Published writes happen on the main actor.
// - dumpSession/copySession are thin wrappers over ExportService; both derive appSlug from
//   the snapshot's displayName (lowercased, non-alphanumeric runs collapsed to a single hyphen).
//
// EXPECTS:
// - startPolling() called from the popover's onAppear; stopPolling() from onDisappear.
//   Safe to call either repeatedly (idempotent).
//
// FAILURE BEHAVIOR:
// - ExportService throwing or returning nil (expired session) -> dumpSession returns nil /
//   copySession returns false. No error surfaced beyond that.
//
// DOES NOT:
// - Republish orchestrator's anySessionOpen/micPermission — views observe the orchestrator
//   directly for that.

@MainActor
public final class PopoverViewModel: ObservableObject {
    @Published public private(set) var sessions: [SessionRegistry.SessionSnapshot] = []
    @Published public private(set) var ringFilled: Int = 0
    @Published public private(set) var ringCapacity: Int = 0

    let registry: SessionRegistry
    let orchestrator: CaptureOrchestrator
    let exportService: ExportService.Type
    private let log = AppLog(category: .export)

    private var pollTimer: DispatchSourceTimer?

    public init(
        registry: SessionRegistry,
        orchestrator: CaptureOrchestrator,
        exportService: ExportService.Type = ExportService.self
    ) {
        self.registry = registry
        self.orchestrator = orchestrator
        self.exportService = exportService
    }

    public func startPolling() {
        guard pollTimer == nil else { return }
        refreshSessions()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { [weak self] in self?.refreshSessions() }
        source.resume()
        pollTimer = source
    }

    public func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    public func refreshSessions() {
        sessions = registry.listSessions()
        ringFilled = registry.filledBytes
        ringCapacity = registry.capacityBytes
    }

    public func dumpSession(_ snapshot: SessionRegistry.SessionSnapshot) -> URL? {
        do {
            let url = try exportService.dumpToFinder(
                stableId: snapshot.stableId,
                registry: registry,
                appSlug: Self.slug(from: snapshot.displayName),
                startTime: snapshot.startedAt
            )
            if let url {
                log.notice("dump to Finder: \(url.lastPathComponent)")
            } else {
                log.warning("dump: session \(snapshot.stableId) expired")
            }
            return url
        } catch {
            log.error("dump failed for session \(snapshot.stableId): \(error)")
            return nil
        }
    }

    public func copySession(_ snapshot: SessionRegistry.SessionSnapshot) -> Bool {
        do {
            let url = try exportService.copyToClipboard(
                stableId: snapshot.stableId,
                registry: registry,
                appSlug: Self.slug(from: snapshot.displayName),
                startTime: snapshot.startedAt
            )
            if let url {
                log.notice("copy to clipboard: \(url.lastPathComponent)")
            } else {
                log.warning("copy: session \(snapshot.stableId) expired")
            }
            return url != nil
        } catch {
            log.error("copy failed for session \(snapshot.stableId): \(error)")
            return false
        }
    }

    private static func slug(from displayName: String) -> String {
        let lowered = displayName.lowercased()
        let allowed = CharacterSet.alphanumerics
        return lowered.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
