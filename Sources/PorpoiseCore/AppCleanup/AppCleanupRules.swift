import Foundation

public struct CleanupApplication: Equatable, Sendable {
    public var url: URL
    public var bundleID: String
    public var name: String
    public var groups: Set<String>
    public init(url: URL, bundleID: String, name: String, groups: Set<String> = []) {
        self.url = url; self.bundleID = bundleID; self.name = name; self.groups = groups
    }
}

public enum CleanupCategory: String, CaseIterable, Sendable {
    case support = "Application Support", caches = "Caches", preferences = "Preferences", containers = "Containers"
    case groups = "Group Containers", savedState = "Saved Application State", agents = "LaunchAgents", logs = "Logs"
    case http = "HTTPStorages", webkit = "WebKit"

    public func identifier(_ name: String) -> String {
        let suffix = self == .preferences || self == .agents ? ".plist" : (self == .savedState ? ".savedState" : "")
        return !suffix.isEmpty && name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
    }
}

public struct CleanupMatch: Equatable, Sendable {
    public var application: CleanupApplication
    public var reason: String
}

public enum AppCleanupRules {
    /// Whole identifiers/names only. A selected app's data is kept if another installed app claims it.
    /// Group containers require an explicit app-group entitlement; names alone never qualify.
    public static func match(
        name: String, identifier: String? = nil, category: CleanupCategory,
        selected: [CleanupApplication], installed: [CleanupApplication], groupOwnershipComplete: Bool = true,
        associatedBundleIDs: Set<String> = []
    ) -> CleanupMatch? {
        if category == .preferences || category == .agents {
            guard name.hasSuffix(".plist") else { return nil }
        }
        if category == .savedState, !name.hasSuffix(".savedState") { return nil }
        let id = identifier ?? category.identifier(name)
        let filenameID = category.identifier(name)
        let selectedPaths = Set(selected.map { $0.url.standardizedFileURL.path })
        let others = installed.filter { !selectedPaths.contains($0.url.standardizedFileURL.path) }
        let sameName: (String, String) -> Bool = {
            $0.compare($1, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
        }
        if category == .groups {
            guard groupOwnershipComplete, !others.contains(where: { app in app.groups.contains { sameName($0, id) || sameName($0, filenameID) } }),
                let app = selected.first(where: { app in app.groups.contains { sameName($0, id) } })
            else { return nil }
            return CleanupMatch(application: app, reason: "App-group entitlement: \(id)")
        }
        guard
            !others.contains(where: { other in
                sameName(other.bundleID, id) || sameName(other.bundleID, filenameID) || sameName(other.name, id) || sameName(other.name, filenameID)
                    || associatedBundleIDs.contains { sameName($0, other.bundleID) }
            })
        else { return nil }
        if let app = selected.first(where: { !$0.bundleID.isEmpty && sameName($0.bundleID, id) }) {
            return CleanupMatch(application: app, reason: "Bundle identifier: \(app.bundleID)")
        }
        // Containers are identified by their bundle metadata, never by a friendly folder name.
        guard category != .containers, let app = selected.first(where: { sameName($0.name, id) }) else { return nil }
        return CleanupMatch(application: app, reason: "Exact application name: \(app.name)")
    }
}
