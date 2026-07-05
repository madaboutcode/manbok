import CoreAudio
import Foundation
import os

// MARK: - CONTRACT: ProcessAudioMonitor
//
// GUARANTEES:
// - otherInputProcesses() returns all HAL audio processes with IsRunningInput=true, excluding own PID
//   and known always-on system processes that permanently hold the mic (alwaysOnProcesses).
// - appName(for:) resolves bundle IDs to human-readable names.
// - All CoreAudio reads are non-destructive (no engine stop required).
//
// EXPECTS:
// - macOS 14+ (Sonoma) — ProcessObjectList APIs unavailable on earlier versions.
//
// DOES NOT:
// - Register listeners (polling only — IsRunningInput listeners are unreliable per spike validation).
// - Start/stop audio engines or capture.

private let log = Logger(subsystem: "ai.manbok.app", category: "process-monitor")

public struct AudioProcessInfo: Equatable, Sendable {
    public let pid: pid_t
    public let bundleID: String
    public let isRunningInput: Bool
}

public final class ProcessAudioMonitor {
    private let ownPID: pid_t

    public init() {
        self.ownPID = getpid()
    }

    public func otherInputProcesses() -> [AudioProcessInfo] {
        let processIDs = readObjectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList
        )

        var result: [AudioProcessInfo] = []
        for objID in processIDs {
            guard let pid = readPID(objID, kAudioProcessPropertyPID),
                  pid != ownPID else { continue }

            let isRunningInput = (readUInt32(objID, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
            guard isRunningInput else { continue }

            let bundleID = readCFString(objID, kAudioProcessPropertyBundleID) ?? ""
            if Self.alwaysOnProcesses.contains(bundleID) { continue }
            if Self.ignoredBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) { continue }
            result.append(AudioProcessInfo(pid: pid, bundleID: bundleID, isRunningInput: true))
        }
        return result
    }

    public static func appName(for bundleIDs: Set<String>) -> String? {
        guard !bundleIDs.isEmpty else { return nil }
        let names = bundleIDs.compactMap { resolveAppName($0) }.sorted()
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    // Processes that permanently hold IsRunningInput=true and must never trigger opportunistic capture.
    private static let alwaysOnProcesses: Set<String> = [
        "com.apple.CoreSpeech",                  // "Hey Siri" always-on listener
        "com.apple.SiriNCService",               // Siri notification center
        "com.apple.accessibility.heard",         // Live Listen (hearing aid feature)
        "com.apple.cmio.ContinuityCaptureAgent", // Continuity Camera agent
    ]

    private static let ignoredBundleIDPrefixes: [String] = [
        "com.apple.Sound-Settings.",             // System Settings → Sound input meter
        "com.apple.systempreferences.",          // System Settings panels
        "com.apple.audio.",                      // Audio system helpers
        "com.apple.preference.",                 // Legacy preference panes
    ]

    private static let knownApps: [String: String] = [
        // MARK: Video conferencing
        "us.zoom.xos": "Zoom",
        "us.zoom.videomeeting": "Zoom",
        "com.apple.FaceTime": "FaceTime",
        "com.apple.avconferenced": "FaceTime",
        "com.microsoft.teams": "Teams",
        "com.microsoft.teams2": "Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.skype.skype": "Skype",
        "com.webex.meetingmanager": "Webex",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.logmein.GoToMeeting": "GoTo Meeting",
        "com.bluejeans.BlueJeans": "BlueJeans",
        "com.discord.Discord": "Discord",

        // MARK: Messaging / calling
        "net.whatsapp.WhatsApp": "WhatsApp",
        "net.whatsapp.WhatsApp.ServiceExtension": "WhatsApp",
        "org.whispersystems.signal-desktop": "Signal",
        "ru.keepcoder.Telegram": "Telegram",
        "jp.naver.line.mac": "LINE",

        // MARK: Voice assistants
        "com.apple.CoreSpeech": "Siri",
        "com.apple.SiriNCService": "Siri",
        "com.amazon.echo": "Alexa",

        // MARK: Browsers
        "com.apple.Safari": "Safari",
        "com.apple.WebKit.GPU": "Safari",
        "com.apple.WebKit.WebContent": "Safari",
        "com.apple.WebKit.Networking": "Safari",
        "com.google.Chrome": "Chrome",
        "com.google.Chrome.helper": "Chrome",
        "org.mozilla.firefox": "Firefox",
        "org.mozilla.plugincontainer": "Firefox",
        "com.brave.Browser": "Brave",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Edge",
        "com.microsoft.edgemac.helper": "Edge",
        "com.operasoftware.Opera": "Opera",
        "com.vivaldi.Vivaldi": "Vivaldi",

        // MARK: Recording / audio production
        "com.apple.QuickTimePlayerX": "QuickTime",
        "com.apple.garageband": "GarageBand",
        "com.apple.logic10": "Logic Pro",
        "org.audacityteam.audacity": "Audacity",
        "com.rogueamoeba.AudioHijack": "Audio Hijack",
        "com.obsproject.obs-studio": "OBS",
        "net.telestream.screenflow10": "ScreenFlow",
        "com.loom.desktop": "Loom",
        "com.descript.Descript": "Descript",

        // MARK: AI / productivity
        "com.openai.chat": "ChatGPT",

        // MARK: Voice recorders
        "com.pxkan.pipit2": "Pipit",
        "com.apple.VoiceMemos": "Voice Memos",

        // MARK: Apple system
        "com.apple.audio.SandboxHelper": "System Audio",
        "com.apple.cmio.ContinuityCaptureAgent": "Continuity Camera",
        "com.apple.accessibility.heard": "Live Listen",
        "com.apple.controlcenter": "Control Center",
    ]

    private static let subprocessSuffixes = [
        "ServiceExtension", "Extension", "helper", "Helper",
        "GPU", "WebContent", "Networking", "xpc", "agent", "Agent",
        "plugincontainer",
    ]

    private static func resolveAppName(_ bundleID: String) -> String? {
        if let known = knownApps[bundleID] { return known }
        if bundleID.isEmpty { return nil }
        var parts = bundleID.split(separator: ".").map(String.init)
        // Strip trailing sub-process suffixes so "WhatsApp.ServiceExtension" → "WhatsApp"
        while let last = parts.last, subprocessSuffixes.contains(last) {
            parts.removeLast()
        }
        guard let last = parts.last else { return nil }
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    // MARK: - CoreAudio HAL helpers

    private func readUInt32(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
        if status != noErr {
            log.warning("readUInt32 obj=\(objectID) failed: OSStatus \(status)")
            return nil
        }
        return value
    }

    private func readPID(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
        if status != noErr {
            log.warning("readPID obj=\(objectID) failed: OSStatus \(status)")
            return nil
        }
        return value
    }

    private func readCFString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ref)
        guard status == noErr, let cf = ref?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private func readObjectIDs(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}
