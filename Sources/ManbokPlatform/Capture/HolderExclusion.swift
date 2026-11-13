import Foundation

// MARK: - CONTRACT: HolderExclusion
//
// GUARANTEES:
// - appGroup(_:) -> String is pure and total: the catalog entry's iconBundleID when the bundle ID is
//   in AppIdentityCatalog, else the raw ID with trailing subprocess suffixes stripped; always
//   lowercased. "" stays "". Chrome's helper IDs, Zoom's two IDs and WhatsApp's extension each map
//   to one key. User exclusions store these keys.
// - HolderExclusion.isExcluded(bundleID) is the ONE exclusion predicate: built-in infrastructure
//   (alwaysOnBundleIDs exact match, ignoredBundleIDPrefixes prefix match) OR appGroup(bundleID) in
//   the user's group set. The lifecycle executor applies it once per snapshot, before the reducer.
// - isBuiltIn(_:) lets the UI hide infrastructure rows; built-ins are not user-editable.
//
// DOES NOT: read the HAL, persist anything (SettingsStore does), or know about sessions.
//
// KNOWN LIMITATION: session keys are raw bundle IDs (Chrome and Chrome.helper are two sessions),
// while exclusion works on groups. A CLI recorder with an empty bundle ID has group "" and shares
// it with every other bundle-less recorder.

public func appGroup(_ bundleID: String) -> String {
    guard !bundleID.isEmpty else { return "" }
    if let entry = AppIdentityCatalog.entry(for: bundleID) { return entry.iconBundleID.lowercased() }
    let stripped = AppIdentityCatalog.suffixStrippedStems(of: bundleID).last ?? bundleID
    return stripped.lowercased()
}

/// Display name for a group key when no running app or session names it (excluded app no longer around).
public func fallbackGroupName(_ group: String) -> String {
    if let name = AppIdentityCatalog.entry(for: group)?.displayName { return name }
    guard let last = group.split(separator: ".").last else { return group }
    return last.prefix(1).uppercased() + last.dropFirst()
}

public struct HolderExclusion: Equatable, Sendable {
    public let userGroups: Set<String>

    public init(userGroups: Set<String> = []) {
        self.userGroups = userGroups
    }

    // Processes that permanently hold the mic and must never trigger capture.
    private static let alwaysOnBundleIDs: Set<String> = [
        "com.apple.CoreSpeech",                  // "Hey Siri" always-on listener
        "com.apple.SiriNCService",               // Siri notification center
        "com.apple.accessibility.heard",         // Live Listen (hearing aid feature)
        "com.apple.cmio.ContinuityCaptureAgent", // Continuity Camera agent
        // ARK (Audio Routing Kit) system-audio routing agent for Rogue Amoeba apps. Lists no input
        // device, so the holder rule ignores it anyway; kept as an explicit built-in.
        "com.rogueamoeba.arkaudiod",
    ]

    private static let ignoredBundleIDPrefixes: [String] = [
        "com.apple.Sound-Settings.",             // System Settings → Sound input meter
        "com.apple.systempreferences.",          // System Settings panels
        "com.apple.audio.",                      // Audio system helpers
        "com.apple.preference.",                 // Legacy preference panes
    ]

    public static func isBuiltIn(_ bundleID: String) -> Bool {
        alwaysOnBundleIDs.contains(bundleID) || ignoredBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    public func isExcluded(_ bundleID: String) -> Bool {
        Self.isBuiltIn(bundleID) || userGroups.contains(appGroup(bundleID))
    }
}

// MARK: - Settings rows

public struct ActiveHolder: Equatable, Sendable {
    public let group: String
    public let bundleID: String
    public let displayName: String

    public init(group: String, bundleID: String, displayName: String) {
        self.group = group
        self.bundleID = bundleID
        self.displayName = displayName
    }
}

public struct ExclusionRow: Equatable, Sendable {
    public enum State: Equatable, Sendable { case usingMicNow, inBuffer, excluded }

    public let group: String
    public let bundleID: String
    public let displayName: String
    public let state: State
    public var isRecording: Bool { state != .excluded }
}

public enum ExclusionRows {
    /// Rows = apps holding a mic now ∪ excluded groups ∪ apps with sessions in the ring, one per group.
    /// Name and icon source preference: holding app, then newest session, then the group key itself.
    /// `sessions` must be newest first (SessionRegistry.listSessions order).
    public static func build(
        holding: [ActiveHolder],
        excluded: Set<String>,
        sessions: [(bundleID: String, displayName: String)]
    ) -> [ExclusionRow] {
        var byGroup: [String: (bundleID: String, name: String)] = [:]
        var holdingGroups = Set<String>()
        for h in holding {
            holdingGroups.insert(h.group)
            if byGroup[h.group] == nil { byGroup[h.group] = (h.bundleID, h.displayName) }
        }
        for s in sessions {
            let group = appGroup(s.bundleID)
            if byGroup[group] == nil { byGroup[group] = (s.bundleID, s.displayName) }
        }
        for group in excluded where byGroup[group] == nil {
            byGroup[group] = (group, fallbackGroupName(group))
        }
        let rows = byGroup.map { group, v in
            ExclusionRow(
                group: group,
                bundleID: v.bundleID,
                displayName: v.name,
                state: excluded.contains(group) ? .excluded : (holdingGroups.contains(group) ? .usingMicNow : .inBuffer)
            )
        }
        func rank(_ s: ExclusionRow.State) -> Int { s == .usingMicNow ? 0 : (s == .inBuffer ? 1 : 2) }
        return rows.sorted {
            (rank($0.state), $0.displayName.lowercased(), $0.group) < (rank($1.state), $1.displayName.lowercased(), $1.group)
        }
    }
}
