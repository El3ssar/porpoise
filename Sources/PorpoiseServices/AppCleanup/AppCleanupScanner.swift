import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import Security

public struct CleanupCandidate: Sendable {
    public var entry: DiskEntry
    public var application: CleanupApplication
    public var category: CleanupCategory
    public var reason: String
    public var bytes: Int64
    public var library: URL
    public var url: URL { entry.url }
}
public struct CleanupReview: Sendable {
    public var applications: [CleanupApplication]
    public var candidates: [CleanupCandidate] = []
    public var errors: [String] = []
    public var groupOwnershipComplete: Bool
}
public struct CleanupCatalog: Sendable {
    public var applications: [CleanupApplication]
    public var groupOwnershipComplete: Bool
    public init(applications: [CleanupApplication], groupOwnershipComplete: Bool = true) {
        self.applications = applications; self.groupOwnershipComplete = groupOwnershipComplete
    }
}

/// Only immediate children of known Library locations are considered. All scan roots/catalogs are injectable.
public enum AppCleanupScanner {
    public static var libraries: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library"), URL(fileURLWithPath: "/Library")]
    }
    public static func application(_ url: URL) -> CleanupApplication? {
        guard var app = applicationInfo(url) else { return nil }
        app.groups = entitlementGroups(url).groups
        return app
    }
    private static func applicationInfo(_ url: URL) -> CleanupApplication? {
        guard url.pathExtension.lowercased() == "app", let entry = try? PhysicalTreeScanner.entry(url), entry.directory, !entry.symlink,
            let data = try? RegularFileData.read(url.appendingPathComponent("Contents/Info.plist"), limit: 2 * 1024 * 1024),
            let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
            let id = info["CFBundleIdentifier"] as? String, !id.isEmpty
        else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        return CleanupApplication(url: url, bundleID: id, name: name)
    }
    private static func entitlementGroups(_ url: URL) -> (groups: Set<String>, complete: Bool) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return ([], false) }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let info = info as? [String: Any], info[kSecCodeInfoUnique as String] != nil
        else { return ([], false) }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        return (Set(entitlements["com.apple.security.application-groups"] as? [String] ?? []), true)
    }
    public static func catalog(roots: [URL] = AppLibrary.roots, including selected: [URL] = [], cancellation: DiskCancellation = DiskCancellation())
        -> CleanupCatalog
    {
        let fm = FileManager.default
        var urls = Set(selected), complete = true
        for root in roots {
            if cancellation.isCancelled { return CleanupCatalog(applications: [], groupOwnershipComplete: false) }
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { complete = false; continue }
            for entry in entries {
                if entry.pathExtension.lowercased() == "app" { urls.insert(entry); continue }
                if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    for child in (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    where child.pathExtension.lowercased() == "app" { urls.insert(child) }
                }
            }
        }
        let applications = urls.sorted { $0.path < $1.path }.compactMap { url -> CleanupApplication? in
            guard !cancellation.isCancelled else { complete = false; return nil }
            guard var app = applicationInfo(url) else { complete = false; return nil }
            let signing = entitlementGroups(url); app.groups = signing.groups; complete = complete && signing.complete
            // Extensions and helpers can claim a group even when the main executable does not.
            for folder in ["PlugIns", "XPCServices", "Helpers", "Library", "Frameworks"] {
                if let contents = fm.enumerator(
                    at: url.appendingPathComponent("Contents/" + folder), includingPropertiesForKeys: [.isSymbolicLinkKey])
                {
                    for case let child as URL in contents {
                        if cancellation.isCancelled { complete = false; break }
                        if ["Resources", "node_modules", "Headers", ".git"].contains(child.lastPathComponent) {
                            contents.skipDescendants(); continue
                        }
                        if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { contents.skipDescendants(); continue }
                        if ["appex", "xpc", "app"].contains(child.pathExtension.lowercased()) {
                            let extra = entitlementGroups(child); app.groups.formUnion(extra.groups); complete = complete && extra.complete
                            contents.skipDescendants()
                        }
                    }
                }
            }
            return app
        }
        return CleanupCatalog(applications: applications, groupOwnershipComplete: complete)
    }
    public static func scan(
        applications: [CleanupApplication], installed: CleanupCatalog, libraries: [URL] = libraries,
        cancellation: DiskCancellation = DiskCancellation(), progress: @escaping (DiskProgress) -> Void = { _ in }
    ) -> CleanupReview {
        var review = CleanupReview(applications: applications, groupOwnershipComplete: installed.groupOwnershipComplete)
        let fm = FileManager.default
        var seen = Set<String>()
        let matcher = AppCleanupRules.Matcher(
            selected: applications, installed: installed.applications, groupOwnershipComplete: installed.groupOwnershipComplete)
        for library in libraries {
            let library = library.resolvingSymlinksInPath()
            for category in CleanupCategory.allCases {
                let folders = category == .preferences ? [category.rawValue, "Preferences/ByHost"] : [category.rawValue]
                for folder in folders {
                    if cancellation.isCancelled { return review }
                    let parent = library.appendingPathComponent(folder)
                    guard fm.fileExists(atPath: parent.path) else { continue }
                    // A category symlink must not lead out of the explicitly selected Library.
                    guard parent.resolvingSymlinksInPath().path == parent.standardizedFileURL.path else { continue }
                    do {
                        for url in try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
                            if cancellation.isCancelled { return review }
                            guard let entry = try? PhysicalTreeScanner.entry(url), !entry.symlink,
                                !([CleanupCategory.preferences, .agents].contains(category) && entry.directory),
                                !([CleanupCategory.containers, .groups, .savedState].contains(category) && !entry.directory),
                                let match = match(url, category: category, matcher: matcher),
                                seen.insert(url.standardizedFileURL.path).inserted
                            else { continue }
                            guard
                                let measurement = TreeMeasure.measure(
                                    [url], followTopLevelLink: false, cancellation: cancellation,
                                    progress: { progress(DiskProgress(files: $0.items, bytes: $0.bytes, path: url.path)) })
                            else { return review }
                            review.errors.append(contentsOf: measurement.errors)
                            guard measurement.errors.isEmpty, !cancellation.isCancelled else { continue }
                            review.candidates.append(
                                CleanupCandidate(
                                    entry: entry, application: match.application, category: category,
                                    reason: match.reason, bytes: measurement.bytes, library: library))
                        }
                    } catch { review.errors.append("\(parent.path): \(error.localizedDescription)") }
                }
            }
        }
        review.candidates.sort { $0.url.path < $1.url.path }
        return review
    }
    private static func match(_ url: URL, category: CleanupCategory, matcher: AppCleanupRules.Matcher) -> CleanupMatch? {
        var identifier = category.identifier(url.lastPathComponent)
        var associated = Set<String>()
        if category == .containers || category == .groups {
            let metadata = url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            if let data = try? RegularFileData.read(metadata, limit: 2 * 1024 * 1024),
                let value = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                let id = value["MCMMetadataIdentifier"] as? String
            {
                identifier = id
            }
        }
        if category == .agents, let data = try? RegularFileData.read(url, limit: 2 * 1024 * 1024),
            let value = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        {
            identifier = value["Label"] as? String ?? identifier
            associated = Set(value["AssociatedBundleIdentifiers"] as? [String] ?? [])
        }
        if category == .preferences, url.deletingLastPathComponent().lastPathComponent == "ByHost",
            let last = identifier.split(separator: ".").last, UUID(uuidString: String(last)) != nil
        {
            identifier = String(identifier.dropLast(last.count + 1))
        }
        if category == .http, identifier.hasSuffix(".binarycookies") { identifier = String(identifier.dropLast(".binarycookies".count)) }
        return matcher.match(name: url.lastPathComponent, identifier: identifier, category: category, associatedBundleIDs: associated)
    }
    /// Review selections are checked again immediately before Trash, including fresh installed-app ownership.
    public static func validate(_ selected: [CleanupCandidate], applications: [CleanupApplication], installed: CleanupCatalog) throws -> [URL] {
        let matcher = AppCleanupRules.Matcher(
            selected: applications, installed: installed.applications, groupOwnershipComplete: installed.groupOwnershipComplete)
        for item in selected {
            let now = try PhysicalTreeScanner.entry(item.url)
            guard !now.symlink, now.identity == item.entry.identity,
                FilePath.contains(path: item.url.deletingLastPathComponent().resolvingSymlinksInPath().path, in: item.library.path),
                item.url.deletingLastPathComponent().resolvingSymlinksInPath().path == item.url.deletingLastPathComponent().standardizedFileURL.path,
                match(item.url, category: item.category, matcher: matcher) != nil
            else { throw FileOperationError.failed("“\(item.url.lastPathComponent)” changed or is now shared. Review the related files again.") }
        }
        return selected.map(\.url)
    }
}
