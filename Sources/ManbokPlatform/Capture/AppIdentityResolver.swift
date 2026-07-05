import AppKit
import Darwin
import Foundation

// MARK: - CONTRACT: AppIdentityResolver
//
// GUARANTEES:
// - resolve(bundleID:pid:) -> String
// - Chain: (1) curated table, case-insensitive; (2) PPID walk (libproc) to parent +
//   NSRunningApplication.localizedName; (3) cosmetic fallback (strip suffixes, titlecase).
// - Thread-safe; caches runtime resolutions per process lifetime.
//
// FAILURE: PPID walk or NSRunningApplication fails -> falls through to next tier.
// DOES NOT: Persist cache. Resolve content inside an app (no tab/site names).

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

    // MARK: - Tier 1: curated table

    private func curatedLookup(_ bundleID: String) -> String? {
        guard !bundleID.isEmpty else { return nil }
        return Self.curatedTable[bundleID.lowercased()]
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
        while let last = parts.last, Self.subprocessSuffixes.contains(last) {
            parts.removeLast()
        }
        guard let last = parts.last, !last.isEmpty else { return bundleID }
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    // MARK: - Tables (keys lowercased for curatedTable; lookup lowercases bundleID first)

    private static let curatedTable: [String: String] = [
        // MARK: Video conferencing
        "us.zoom.xos": "Zoom",
        "us.zoom.videomeeting": "Zoom",
        "com.apple.facetime": "FaceTime",
        "com.apple.avconferenced": "FaceTime",
        "com.microsoft.teams": "Teams",
        "com.microsoft.teams2": "Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.skype.skype": "Skype",
        "com.webex.meetingmanager": "Webex",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.logmein.gotomeeting": "GoTo Meeting",
        "com.bluejeans.bluejeans": "BlueJeans",
        "com.discord.discord": "Discord",

        // MARK: Messaging / calling
        "net.whatsapp.whatsapp": "WhatsApp",
        "net.whatsapp.whatsapp.serviceextension": "WhatsApp",
        "org.whispersystems.signal-desktop": "Signal",
        "ru.keepcoder.telegram": "Telegram",
        "jp.naver.line.mac": "LINE",

        // MARK: Voice assistants
        "com.apple.corespeech": "Siri",
        "com.apple.sirincservice": "Siri",
        "com.apple.siri": "Siri",
        "com.amazon.echo": "Alexa",

        // MARK: Browsers
        "com.apple.safari": "Safari",
        "com.apple.webkit.gpu": "Safari",
        "com.apple.webkit.webcontent": "Safari",
        "com.apple.webkit.networking": "Safari",
        "com.google.chrome": "Chrome",
        "com.google.chrome.helper": "Chrome",
        "com.google.chrome.helper.renderer": "Chrome",
        "org.mozilla.firefox": "Firefox",
        "org.mozilla.plugincontainer": "Firefox",
        "com.brave.browser": "Brave",
        "company.thebrowser.browser": "Arc",
        "com.microsoft.edgemac": "Edge",
        "com.microsoft.edgemac.helper": "Edge",
        "com.operasoftware.opera": "Opera",
        "com.vivaldi.vivaldi": "Vivaldi",
        "org.chromium.chromium": "Chromium",

        // MARK: Recording / audio production
        "com.apple.quicktimeplayerx": "QuickTime",
        "com.apple.garageband": "GarageBand",
        "com.apple.logic10": "Logic Pro",
        "org.audacityteam.audacity": "Audacity",
        "com.rogueamoeba.audiohijack": "Audio Hijack",
        "com.rogueamoeba.loopback": "Loopback",
        "com.obsproject.obs-studio": "OBS",
        "net.telestream.screenflow10": "ScreenFlow",
        "com.loom.desktop": "Loom",
        "com.descript.descript": "Descript",

        // MARK: AI / productivity
        "com.openai.chat": "ChatGPT",
        "com.anthropic.claudefordesktop": "Claude",
        "com.superwhisper.superwhisper": "superwhisper",
        "com.goodsnooze.macwhisper": "MacWhisper",
        "com.lmstudio.lmstudio": "LM Studio",
        "dev.zed.zed": "Zed",

        // MARK: Voice recorders / media
        "com.pxkan.pipit2": "Pipit",
        "com.apple.voicememos": "Voice Memos",
        "com.spotify.client": "Spotify",

        // MARK: Remote access
        "com.rustdesk.rustdesk": "RustDesk",

        // MARK: Apple system
        "com.apple.audio.sandboxhelper": "System Audio",
        "com.apple.cmio.continuitycaptureagent": "Continuity Camera",
        "com.apple.accessibility.heard": "Live Listen",
        "com.apple.controlcenter": "Control Center",
        "com.apple.notes": "Notes",
    ]

    private static let subprocessSuffixes: Set<String> = [
        "ServiceExtension", "Extension", "helper", "Helper",
        "GPU", "WebContent", "Networking", "xpc", "agent", "Agent",
        "plugincontainer", "renderer", "Renderer",
    ]
}
