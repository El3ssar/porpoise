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
        Matcher(selected: selected, installed: installed, groupOwnershipComplete: groupOwnershipComplete).match(
            name: name, identifier: identifier, category: category, associatedBundleIDs: associatedBundleIDs)
    }

    /// Prepared once for a scan/revalidation. Whole-name folding preserves the POSIX
    /// case-insensitive comparison while avoiding an entries × installed-apps search.
    public struct Matcher: Sendable {
        private static let locale = Locale(identifier: "en_US_POSIX")
        private var selectedIDs: [String: CleanupApplication] = [:]
        private var selectedNames: [String: CleanupApplication] = [:]
        private var selectedGroups: [String: CleanupApplication] = [:]
        private var otherIDs = Set<String>(), otherNames = Set<String>(), otherGroups = Set<String>()
        private let groupOwnershipComplete: Bool
        private static func key(_ value: String) -> String {
            value.folding(options: .caseInsensitive, locale: locale).precomposedStringWithCanonicalMapping
        }
        public init(selected: [CleanupApplication], installed: [CleanupApplication], groupOwnershipComplete: Bool = true) {
            self.groupOwnershipComplete = groupOwnershipComplete
            let paths = Set(selected.map { $0.url.standardizedFileURL.path })
            for app in selected {
                let id = Self.key(app.bundleID), name = Self.key(app.name)
                if !id.isEmpty, selectedIDs[id] == nil { selectedIDs[id] = app }
                if selectedNames[name] == nil { selectedNames[name] = app }
                for group in app.groups where selectedGroups[Self.key(group)] == nil { selectedGroups[Self.key(group)] = app }
            }
            for app in installed where !paths.contains(app.url.standardizedFileURL.path) {
                otherIDs.insert(Self.key(app.bundleID)); otherNames.insert(Self.key(app.name))
                otherGroups.formUnion(app.groups.map(Self.key))
            }
        }
        public func match(
            name: String, identifier: String? = nil, category: CleanupCategory, associatedBundleIDs: Set<String> = []
        ) -> CleanupMatch? {
            if category == .preferences || category == .agents {
                guard name.hasSuffix(".plist") else { return nil }
            }
            if category == .savedState, !name.hasSuffix(".savedState") { return nil }
            let rawID = identifier ?? category.identifier(name)
            let id = Self.key(rawID), filenameID = Self.key(category.identifier(name))
            if category == .groups {
                guard groupOwnershipComplete, !otherGroups.contains(id), !otherGroups.contains(filenameID), let app = selectedGroups[id]
                else { return nil }
                return CleanupMatch(application: app, reason: "App-group entitlement: \(rawID)")
            }
            guard !otherIDs.contains(id), !otherIDs.contains(filenameID), !otherNames.contains(id), !otherNames.contains(filenameID),
                !associatedBundleIDs.contains(where: { otherIDs.contains(Self.key($0)) })
            else { return nil }
            if let app = selectedIDs[id] { return CleanupMatch(application: app, reason: "Bundle identifier: \(app.bundleID)") }
            // Containers require bundle metadata rather than friendly folder names.
            guard category != .containers, let app = selectedNames[id] else { return nil }
            return CleanupMatch(application: app, reason: "Exact application name: \(app.name)")
        }
    }
}
