import AppKit
import Darwin
import Foundation

// MARK: - CONTRACT: AppIdentityResolver
//
// GUARANTEES:
// - resolve(bundleID:pid:) -> String
// - Chain: (1) AppIdentityCatalog lookup, case-insensitive; (2) PPID walk (libproc) to
//   parent + NSRunningApplication.localizedName; (3) cosmetic fallback (strip suffixes
//   using AppIdentityCatalog's suffix set, titlecase).
// - Thread-safe; caches runtime resolutions per process lifetime.
//
// FAILURE: PPID walk or NSRunningApplication fails -> falls through to next tier.
// DOES NOT: Persist cache. Resolve content inside an app (no tab/site names). Own the
// bundleID->name/icon table (that's AppIdentityCatalog's job).

public final class AppIdentityResolver {
    public static let shared = AppIdentityResolver()

    private var cache: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func resolve(bundleID: String, pid: pid_t) -> String {
        lock.lock()
        if let cached = cache[bundleID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved: String
        if let curated = curatedLookup(bundleID) {
            resolved = curated
        } else if let walked = ppidWalkLookup(pid: pid) {
            resolved = walked
        } else {
            resolved = cosmeticFallback(bundleID)
        }

        lock.lock()
        cache[bundleID] = resolved
        lock.unlock()
        return resolved
    }

    // MARK: - Tier 1: curated catalog

    private func curatedLookup(_ bundleID: String) -> String? {
        AppIdentityCatalog.entry(for: bundleID)?.displayName
    }

    // MARK: - Tier 2: PPID walk

    private func ppidWalkLookup(pid: pid_t) -> String? {
        var currentPID = pid
        var hops = 0
        while hops < 20 {
            guard let parent = parentPID(of: currentPID) else { break }
            if let app = NSRunningApplication(processIdentifier: parent), let name = app.localizedName {
                return name
            }
            if parent <= 1 { break }
            currentPID = parent
            hops += 1
        }
        return nil
    }

    private func parentPID(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let status = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard status == 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    // MARK: - Tier 3: cosmetic fallback

    private func cosmeticFallback(_ bundleID: String) -> String {
        guard !bundleID.isEmpty else { return bundleID }
        var parts = bundleID.split(separator: ".").map(String.init)
        while let last = parts.last, AppIdentityCatalog.subprocessSuffixes.contains(last) {
            parts.removeLast()
        }
        guard let last = parts.last, !last.isEmpty else { return bundleID }
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}
