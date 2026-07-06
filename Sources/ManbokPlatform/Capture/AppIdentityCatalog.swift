import Foundation

// MARK: - CONTRACT: AppIdentityCatalog
//
// GUARANTEES:
// - entry(for:) -> Entry? — case-insensitive exact match against a static, immutable
//   bundleID -> {displayName, iconBundleID} table. Pure (no I/O, no process access).
// - iconCandidates(for:) -> [String] — deterministic ordered candidates for icon lookup:
//   (1) the catalog entry's iconBundleID (if any), (2) suffix-stripped stems of the raw
//   bundleID (longest stem first, i.e. least-stripped first), (3) the raw bundleID last.
//   No duplicates (case-insensitive).
// - Thread-safe: table and suffix set are immutable static data, no shared mutable state.
//
// EXPECTS: nothing. Empty bundleID -> nil entry, [] candidates.
// DOES NOT: touch AppKit, NSWorkspace, processes, or any caching. Pure string logic only.

public struct AppIdentityCatalog {
    public struct Entry: Equatable {
        public let displayName: String
        public let iconBundleID: String

        public init(displayName: String, iconBundleID: String) {
            self.displayName = displayName
            self.iconBundleID = iconBundleID
        }
    }

    public static func entry(for bundleID: String) -> Entry? {
        guard !bundleID.isEmpty else { return nil }
        return table[bundleID.lowercased()]
    }

    public static func iconCandidates(for bundleID: String) -> [String] {
        guard !bundleID.isEmpty else { return [] }

        var seen = Set<String>()
        var candidates: [String] = []

        func append(_ candidate: String) {
            let key = candidate.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            candidates.append(candidate)
        }

        if let catalogIconID = entry(for: bundleID)?.iconBundleID {
            append(catalogIconID)
        }
        for stem in suffixStrippedStems(of: bundleID) {
            append(stem)
        }
        append(bundleID)

        return candidates
    }

    /// Progressively strips known subprocess suffixes from the trailing dot-separated
    /// components of `bundleID`, returning each intermediate stem, longest (least
    /// stripped) first. Stops at the first component that is not a recognized suffix.
    static func suffixStrippedStems(of bundleID: String) -> [String] {
        var parts = bundleID.split(separator: ".").map(String.init)
        var stems: [String] = []
        while let last = parts.last, subprocessSuffixes.contains(last) {
            parts.removeLast()
            guard !parts.isEmpty else { break }
            stems.append(parts.joined(separator: "."))
        }
        return stems
    }

    // MARK: - Tables (keys lowercased; entry(for:) lowercases lookup input first)

    static let subprocessSuffixes: Set<String> = [
        "ServiceExtension", "Extension", "helper", "Helper",
        "GPU", "WebContent", "Networking", "xpc", "agent", "Agent",
        "plugincontainer", "renderer", "Renderer",
    ]

    private static let table: [String: Entry] = [
        // MARK: Video conferencing
        "us.zoom.xos": Entry(displayName: "Zoom", iconBundleID: "us.zoom.xos"),
        "us.zoom.videomeeting": Entry(displayName: "Zoom", iconBundleID: "us.zoom.xos"),
        "com.apple.facetime": Entry(displayName: "FaceTime", iconBundleID: "com.apple.facetime"),
        "com.apple.avconferenced": Entry(displayName: "FaceTime", iconBundleID: "com.apple.facetime"),
        "com.microsoft.teams": Entry(displayName: "Teams", iconBundleID: "com.microsoft.teams"),
        "com.microsoft.teams2": Entry(displayName: "Teams", iconBundleID: "com.microsoft.teams2"),
        "com.tinyspeck.slackmacgap": Entry(displayName: "Slack", iconBundleID: "com.tinyspeck.slackmacgap"),
        "com.skype.skype": Entry(displayName: "Skype", iconBundleID: "com.skype.skype"),
        "com.webex.meetingmanager": Entry(displayName: "Webex", iconBundleID: "com.webex.meetingmanager"),
        "com.cisco.webexmeetingsapp": Entry(displayName: "Webex", iconBundleID: "com.cisco.webexmeetingsapp"),
        "com.logmein.gotomeeting": Entry(displayName: "GoTo Meeting", iconBundleID: "com.logmein.gotomeeting"),
        "com.bluejeans.bluejeans": Entry(displayName: "BlueJeans", iconBundleID: "com.bluejeans.bluejeans"),
        "com.discord.discord": Entry(displayName: "Discord", iconBundleID: "com.discord.discord"),

        // MARK: Messaging / calling
        "net.whatsapp.whatsapp": Entry(displayName: "WhatsApp", iconBundleID: "net.whatsapp.whatsapp"),
        "net.whatsapp.whatsapp.serviceextension": Entry(displayName: "WhatsApp", iconBundleID: "net.whatsapp.whatsapp"),
        "org.whispersystems.signal-desktop": Entry(displayName: "Signal", iconBundleID: "org.whispersystems.signal-desktop"),
        "ru.keepcoder.telegram": Entry(displayName: "Telegram", iconBundleID: "ru.keepcoder.telegram"),
        "jp.naver.line.mac": Entry(displayName: "LINE", iconBundleID: "jp.naver.line.mac"),

        // MARK: Voice assistants
        "com.apple.corespeech": Entry(displayName: "Siri", iconBundleID: "com.apple.corespeech"),
        "com.apple.sirincservice": Entry(displayName: "Siri", iconBundleID: "com.apple.siri"),
        "com.apple.siri": Entry(displayName: "Siri", iconBundleID: "com.apple.siri"),
        "com.amazon.echo": Entry(displayName: "Alexa", iconBundleID: "com.amazon.echo"),

        // MARK: Browsers
        "com.apple.safari": Entry(displayName: "Safari", iconBundleID: "com.apple.safari"),
        "com.apple.webkit.gpu": Entry(displayName: "Safari", iconBundleID: "com.apple.safari"),
        "com.apple.webkit.webcontent": Entry(displayName: "Safari", iconBundleID: "com.apple.safari"),
        "com.apple.webkit.networking": Entry(displayName: "Safari", iconBundleID: "com.apple.safari"),
        "com.google.chrome": Entry(displayName: "Chrome", iconBundleID: "com.google.chrome"),
        "com.google.chrome.helper": Entry(displayName: "Chrome", iconBundleID: "com.google.chrome"),
        "com.google.chrome.helper.renderer": Entry(displayName: "Chrome", iconBundleID: "com.google.chrome"),
        "org.mozilla.firefox": Entry(displayName: "Firefox", iconBundleID: "org.mozilla.firefox"),
        "org.mozilla.plugincontainer": Entry(displayName: "Firefox", iconBundleID: "org.mozilla.firefox"),
        "com.brave.browser": Entry(displayName: "Brave", iconBundleID: "com.brave.browser"),
        "company.thebrowser.browser": Entry(displayName: "Arc", iconBundleID: "company.thebrowser.browser"),
        "com.microsoft.edgemac": Entry(displayName: "Edge", iconBundleID: "com.microsoft.edgemac"),
        "com.microsoft.edgemac.helper": Entry(displayName: "Edge", iconBundleID: "com.microsoft.edgemac"),
        "com.operasoftware.opera": Entry(displayName: "Opera", iconBundleID: "com.operasoftware.opera"),
        "com.vivaldi.vivaldi": Entry(displayName: "Vivaldi", iconBundleID: "com.vivaldi.vivaldi"),
        "org.chromium.chromium": Entry(displayName: "Chromium", iconBundleID: "org.chromium.chromium"),

        // MARK: Recording / audio production
        "com.apple.quicktimeplayerx": Entry(displayName: "QuickTime", iconBundleID: "com.apple.quicktimeplayerx"),
        "com.apple.garageband": Entry(displayName: "GarageBand", iconBundleID: "com.apple.garageband"),
        "com.apple.logic10": Entry(displayName: "Logic Pro", iconBundleID: "com.apple.logic10"),
        "org.audacityteam.audacity": Entry(displayName: "Audacity", iconBundleID: "org.audacityteam.audacity"),
        "com.rogueamoeba.audiohijack": Entry(displayName: "Audio Hijack", iconBundleID: "com.rogueamoeba.audiohijack"),
        "com.rogueamoeba.loopback": Entry(displayName: "Loopback", iconBundleID: "com.rogueamoeba.loopback"),
        "com.obsproject.obs-studio": Entry(displayName: "OBS", iconBundleID: "com.obsproject.obs-studio"),
        "net.telestream.screenflow10": Entry(displayName: "ScreenFlow", iconBundleID: "net.telestream.screenflow10"),
        "com.loom.desktop": Entry(displayName: "Loom", iconBundleID: "com.loom.desktop"),
        "com.descript.descript": Entry(displayName: "Descript", iconBundleID: "com.descript.descript"),

        // MARK: AI / productivity
        "com.openai.chat": Entry(displayName: "ChatGPT", iconBundleID: "com.openai.chat"),
        "com.anthropic.claudefordesktop": Entry(displayName: "Claude", iconBundleID: "com.anthropic.claudefordesktop"),
        "com.superwhisper.superwhisper": Entry(displayName: "superwhisper", iconBundleID: "com.superwhisper.superwhisper"),
        "com.goodsnooze.macwhisper": Entry(displayName: "MacWhisper", iconBundleID: "com.goodsnooze.macwhisper"),
        "com.lmstudio.lmstudio": Entry(displayName: "LM Studio", iconBundleID: "com.lmstudio.lmstudio"),
        "dev.zed.zed": Entry(displayName: "Zed", iconBundleID: "dev.zed.zed"),

        // MARK: Voice recorders / media
        "com.pxkan.pipit2": Entry(displayName: "Pipit", iconBundleID: "com.pxkan.pipit2"),
        "com.apple.voicememos": Entry(displayName: "Voice Memos", iconBundleID: "com.apple.voicememos"),
        "com.spotify.client": Entry(displayName: "Spotify", iconBundleID: "com.spotify.client"),

        // MARK: Remote access
        "com.rustdesk.rustdesk": Entry(displayName: "RustDesk", iconBundleID: "com.rustdesk.rustdesk"),

        // MARK: Apple system (faceless daemons — no real app bundle; icon lookup will
        // fail the has-icon check and the letter tile takes over, by design)
        "com.apple.audio.sandboxhelper": Entry(displayName: "System Audio", iconBundleID: "com.apple.audio.sandboxhelper"),
        "com.apple.cmio.continuitycaptureagent": Entry(displayName: "Continuity Camera", iconBundleID: "com.apple.cmio.continuitycaptureagent"),
        "com.apple.accessibility.heard": Entry(displayName: "Live Listen", iconBundleID: "com.apple.accessibility.heard"),
        "com.apple.controlcenter": Entry(displayName: "Control Center", iconBundleID: "com.apple.controlcenter"),
        "com.apple.notes": Entry(displayName: "Notes", iconBundleID: "com.apple.notes"),
    ]
}
