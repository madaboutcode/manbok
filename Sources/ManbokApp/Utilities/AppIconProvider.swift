import AppKit

final class AppIconProvider: @unchecked Sendable {
    static let shared = AppIconProvider()

    private let cache = NSCache<NSString, NSImage>()

    func icon(for bundleID: String) -> NSImage? {
        let key = bundleID as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}
