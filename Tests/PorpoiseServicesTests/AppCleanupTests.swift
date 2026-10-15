import Darwin
import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct AppCleanupScannerTests {
    private func signBundle(_ url: URL, id: String, groups: [String], entitlements: URL) throws {
        let executable = url.appendingPathComponent("Contents/MacOS/fixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)
        let info = ["CFBundleIdentifier": id, "CFBundleExecutable": "fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
            to: url.appendingPathComponent("Contents/Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.application-groups": groups], format: .xml, options: 0).write(
            to: entitlements)
        _ = try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", entitlements.path, url.path])
    }
    @Test func signedMainAndHelperGroupClaimsAreDiscoveredInVendorSubfolders() throws {
        let s = try Scratch()
        let url = s.path("Applications/Vendor/Example.app")
        try signBundle(
            url.appendingPathComponent("Contents/Helpers/Helper.app"), id: "com.test.helper", groups: ["group.helper"],
            entitlements: s.path("helper.entitlements"))
        try signBundle(url, id: "com.test.example", groups: ["group.main"], entitlements: s.path("main.entitlements"))
        let catalog = AppCleanupScanner.catalog(roots: [s.path("Applications"), s.path("missing")])
        #expect(catalog.groupOwnershipComplete)
        #expect(catalog.applications.count == 1)
        #expect(catalog.applications.first?.groups == ["group.main", "group.helper"])
    }
    @Test func launchAgentOwnershipAndUnreadableFoldersAreHandledConservatively() throws {
        let s = try Scratch(); let selected = try app(s, "Example", "com.test.example")
        let other = try app(s, "Other", "com.test.other")
        let folder = try s.folder("Library/LaunchAgents")
        for (name, associated) in [("own.plist", [selected.bundleID]), ("shared.plist", [selected.bundleID, other.bundleID])] {
            let value: [String: Any] = ["Label": selected.bundleID, "AssociatedBundleIdentifiers": associated]
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: folder.appendingPathComponent(name))
        }
        let logs = try s.folder("Library/Logs")
        let cache = try s.folder("Library/Caches/com.test.example")
        try s.file("Library/Caches/com.test.example/data", "private")
        try #require(chmod(cache.path, 0o000) == 0)
        defer { chmod(cache.path, 0o755) }
        try s.file("Library/Logs/com.test.example/data", "private")
        try #require(chmod(logs.path, 0o000) == 0)
        defer { chmod(logs.path, 0o755) }
        let review = AppCleanupScanner.scan(
            applications: [selected], installed: CleanupCatalog(applications: [selected, other]), libraries: [s.path("Library")])
        #expect(review.candidates.map(\.url.lastPathComponent) == ["own.plist"])
        #expect(!review.errors.isEmpty)
    }
    private func app(_ s: Scratch, _ name: String, _ id: String, groups: Set<String> = []) throws -> CleanupApplication {
        let url = try s.folder("Applications/\(name).app/Contents").deletingLastPathComponent()
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .binary, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        return CleanupApplication(url: url, bundleID: id, name: name, groups: groups)
    }
    @Test func realLibraryMatchingAndSharedContainerExclusion() throws {
        let s = try Scratch()
        let selected = try app(s, "Example", "com.test.example", groups: ["group.private", "group.shared"])
        let other = try app(s, "Other", "com.test.other", groups: ["group.shared"])
        let library = try s.folder("Library")
        for category in CleanupCategory.allCases where category != .groups {
            let suffix = category == .preferences || category == .agents ? ".plist" : (category == .savedState ? ".savedState" : "")
            let path = "Library/\(category.rawValue)/com.test.example\(suffix)"
            try s.file(path + ([CleanupCategory.containers, .savedState].contains(category) ? "/data" : ""), "data")
        }
        try s.file("Library/Application Support/Example/data", "1234567")
        try s.file("Library/Application Support/Example Pro/keep", "other")
        try s.file("Library/Group Containers/group.shared/keep", "shared")
        try s.file("Library/Group Containers/group.private/own", "own")
        try s.file("Library/Group Containers/Example/keep", "name is insufficient")
        try s.file("Library/Preferences/ByHost/com.test.example.\(UUID()).plist", "byhost")
        try s.file("Library/HTTPStorages/com.test.example.binarycookies", "cookies")
        let catalog = CleanupCatalog(applications: [selected, other])
        let review = AppCleanupScanner.scan(applications: [selected], installed: catalog, libraries: [library])
        #expect(review.errors.isEmpty)
        #expect(review.candidates.count == 13)
        #expect(review.candidates.allSatisfy { !$0.reason.isEmpty && $0.bytes > 0 })
        #expect(!review.candidates.contains { $0.url.path.contains("group.shared") || $0.url.path.contains("Example Pro") })
        #expect(try AppCleanupScanner.validate(review.candidates, applications: [selected], installed: catalog).count == 13)
        let shared = try #require(review.candidates.first { $0.category == .groups })
        var newOther = other; newOther.groups.insert("group.private")
        #expect(throws: (any Error).self) {
            try AppCleanupScanner.validate([shared], applications: [selected], installed: CleanupCatalog(applications: [selected, newOther]))
        }
    }
    @Test func metadataMatchingAndUnsafePathsAreExcluded() throws {
        let s = try Scratch(); let selected = try app(s, "Example", "com.test.example")
        let library = try s.folder("Library"); let outside = try s.folder("outside")
        try s.file("outside/com.test.example", "keep")
        try s.symlink("Library/Caches", to: outside.path)
        let groups = try s.folder("Library/Group Containers")
        try s.file("Library/Group Containers/Example/shared", "keep")
        try s.symlink("Library/Logs", to: groups.path)
        try s.folder("Library/Containers/UUID")
        let data = try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": selected.bundleID], format: .binary, options: 0)
        try data.write(to: s.path("Library/Containers/UUID/.com.apple.containermanagerd.metadata.plist"))
        try s.file("Library/Application Support/real", "keep")
        try s.symlink("Library/Application Support/Example", to: outside.path)
        let catalog = CleanupCatalog(applications: [selected])
        let review = AppCleanupScanner.scan(applications: [selected], installed: catalog, libraries: [library])
        #expect(review.candidates.map(\.url.lastPathComponent) == ["UUID"])
        let item = try #require(review.candidates.first)
        try FileManager.default.moveItem(at: item.url, to: s.path("old-container"))
        try s.folder("Library/Containers/UUID")
        try data.write(to: s.path("Library/Containers/UUID/.com.apple.containermanagerd.metadata.plist"))
        #expect(throws: (any Error).self) { try AppCleanupScanner.validate([item], applications: [selected], installed: catalog) }
        let token = DiskCancellation(); token.cancel()
        #expect(AppCleanupScanner.scan(applications: [selected], installed: catalog, libraries: [library], cancellation: token).candidates.isEmpty)
    }
    @Test func unsignedCatalogKeepsUnverifiableGroupOwnership() throws {
        let s = try Scratch(); let selected = try app(s, "Example", "com.test.example")
        let catalog = AppCleanupScanner.catalog(roots: [s.path("Applications")])
        #expect(catalog.applications.count == 1)
        #expect(catalog.applications.first?.bundleID == selected.bundleID)
        #expect(!catalog.groupOwnershipComplete)
        #expect(AppCleanupScanner.application(s.path("Applications/missing.app")) == nil)
    }
}
