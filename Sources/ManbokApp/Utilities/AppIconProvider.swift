import AppKit
import ManbokPlatform

// MARK: - CONTRACT: AppIconProvider
//
// GUARANTEES:
// - icon(for bundleID:) -> NSImage? returns an image only when some candidate from
//   AppIdentityCatalog.iconCandidates(for:) resolves via NSWorkspace.urlForApplication
//   to a bundle whose Info.plist declares CFBundleIconFile or CFBundleIconName — i.e. a
//   real, intentional icon, never the synthesized generic icon for a faceless bundle.
// - Tries candidates in order; the first candidate that passes the has-icon check wins.
// - Caches positive AND negative results per raw bundleID (nil is a cacheable outcome).
//
// FAILURE BEHAVIOR: any candidate lookup failure -> falls through to the next candidate
// -> nil if none pass. Never throws, never blocks beyond LaunchServices query cost
// (bounded, cached after first render).
// DOES NOT: know about helper processes or ppid walks (AppIdentityCatalog's job);
// render fallback tiles (AppIconView's job).
// KNOWN LIMITATIONS: cache never evicts (unlike the NSCache it replaced) — accepted
// because distinct bundle IDs per run are bounded to the few apps that capture audio.

final class AppIconProvider: @unchecked Sendable {
    static let shared = AppIconProvider()

    // Double-optional value: an absent key means "not looked up yet"; a present key
    // with a nil value is a cached negative (no candidate had a real icon).
    private var cache: [String: NSImage?] = [:]
    private let lock = NSLock()

    func icon(for bundleID: String) -> NSImage? {
        lock.lock()
        if let cached = cache[bundleID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = resolveIcon(for: bundleID)

        lock.lock()
        cache[bundleID] = resolved
        lock.unlock()
        return resolved
    }

    private func resolveIcon(for bundleID: String) -> NSImage? {
        for candidate in AppIdentityCatalog.iconCandidates(for: bundleID) {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate),
                  bundleDeclaresIcon(at: appURL) else {
                continue
            }
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        return nil
    }

    private func bundleDeclaresIcon(at url: URL) -> Bool {
        guard let bundle = Bundle(url: url) else { return false }
        if let iconFile = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String, !iconFile.isEmpty {
            return true
        }
        if let iconName = bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String, !iconName.isEmpty {
            return true
        }
        return false
    }
}
