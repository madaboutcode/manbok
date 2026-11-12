import CoreAudio
import Foundation
import ManbokCore
import os

// MARK: - CONTRACT: ProcessAudioMonitor
//
// GUARANTEES:
// - holderSnapshot() returns one HolderObservation per HAL audio process that holds a microphone:
//   its pdv# input scope (kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput; Global scope
//   returns empty) contains at least one device with input streams (D5). IsRunningInput is not
//   read and decides nothing: process taps set it without opening a mic.
// - Read order per process object: pdv# input scope first; PID and bundle ID only when that list is
//   non-empty. Excludes own PID, alwaysOnProcesses and ignoredBundleIDPrefixes (built-in, not user
//   exclusions). A holder never has an empty device set.
// - liveInputDevices = system devices with at least one input stream, read in the same call.
// - All CoreAudio reads are non-destructive. A failed read yields [] / skips the process and is
//   logged at .warning once when it first appears (same object, selector and status are silent on
//   later ticks until they stop failing and fail again).
// - appName(for:) resolves bundle IDs to human-readable names.
//
// EXPECTS:
// - macOS 14+ (Sonoma) — ProcessObjectList APIs unavailable on earlier versions.
// - holderSnapshot() is called from one queue at a time (the failure de-duplication is unsynchronized).
//
// DOES NOT:
// - Register listeners (polling only — IsRunningInput listeners are unreliable per spike validation).
// - Start/stop audio engines or capture.
// - Apply user exclusions or decide demand (the executor and DemandReducer do).

private let log = Logger(subsystem: "ai.manbok.app", category: "process-monitor")

public struct HolderSnapshot: Equatable, Sendable {
    public let holders: [HolderObservation]
    public let liveInputDevices: Set<UInt32>

    public init(holders: [HolderObservation], liveInputDevices: Set<UInt32>) {
        self.holders = holders
        self.liveInputDevices = liveInputDevices
    }
}

public final class ProcessAudioMonitor {
    private let ownPID: pid_t
    private var failuresLastTick: Set<String> = []
    private var failuresThisTick: Set<String> = []

    public init() {
        self.ownPID = getpid()
    }

    public func holderSnapshot() -> HolderSnapshot {
        failuresLastTick = failuresThisTick
        failuresThisTick = []

        let processIDs = readObjectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal
        )

        var holders: [HolderObservation] = []
        for objID in processIDs {
            let devices = inputDeviceIDs(for: objID)
            guard !devices.isEmpty else { continue }

            guard let pid = readPID(objID, kAudioProcessPropertyPID), pid != ownPID else { continue }
            let bundleID = readCFString(objID, kAudioProcessPropertyBundleID) ?? ""
            if Self.alwaysOnProcesses.contains(bundleID) { continue }
            if Self.ignoredBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) { continue }
            holders.append(HolderObservation(appID: bundleID, pid: pid, inputDevices: Set(devices)))
        }

        let live = readObjectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal
        ).filter { hasInputStreams($0) }
        return HolderSnapshot(holders: holders, liveInputDevices: Set(live))
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

    /// Warns when a failure first appears; the same failure on consecutive ticks stays silent.
    private func noteFailure(_ message: String) {
        failuresThisTick.insert(message)
        if !failuresLastTick.contains(message) { log.warning("\(message)") }
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
            noteFailure("readPID obj=\(objectID) failed: OSStatus \(status)")
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

    private func readObjectIDs(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size)
        guard sizeStatus == noErr, size > 0 else {
            if sizeStatus != noErr {
                noteFailure("readObjectIDs obj=\(objectID) selector=\(selector) scope=\(scope) getSizeFailed: OSStatus \(sizeStatus)")
            }
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let dataStatus = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ids)
        guard dataStatus == noErr else {
            noteFailure("readObjectIDs obj=\(objectID) selector=\(selector) scope=\(scope) getDataFailed: OSStatus \(dataStatus)")
            return []
        }
        return ids
    }

    private func inputDeviceIDs(for processObjectID: AudioObjectID) -> [AudioDeviceID] {
        let allDevices = readObjectIDs(processObjectID, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
        return allDevices.filter { hasInputStreams($0) }
    }

    private func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }
}
