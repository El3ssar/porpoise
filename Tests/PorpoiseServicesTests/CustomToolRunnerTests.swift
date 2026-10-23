import Foundation
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@Suite(.serialized) @MainActor struct CustomToolRunnerTests {
    private func context(_ scratch: Scratch, names: [String] = []) -> CustomToolContext {
        CustomToolContext(folder: scratch.url, items: names.map { FileItem(url: scratch.path($0), name: $0, isDirectory: false) })
    }
    @Test(.isolatedSettings) func settingsRoundTripRejectsWholeInvalidImportAndNeverDiscoversFiles() throws {
        let scratch = try Scratch()
        let tools = CustomToolDocument.examples
        try Settings.shared.saveCustomTools(tools)
        #expect(Settings.shared.customTools == tools)
        var invalid = CustomToolDocument(tools: tools); invalid.tools[1].executable = "relative"
        #expect(throws: (any Error).self) { try Settings.shared.importCustomTools(JSONEncoder().encode(invalid)) }
        #expect(Settings.shared.customTools == tools)
        try Settings.shared.saveCustomTools([])
        try CustomToolDocument(tools: tools).encoded().write(to: scratch.path("porpoise-tools.json"))
        #expect(Settings.shared.customTools.isEmpty)
        let runner = CustomToolRunner()
        #expect(throws: (any Error).self) { try runner.start(id: tools[0].id, context: context(scratch)) }
        #expect(runner.runs.isEmpty)
        var folderTool = tools[1]; folderTool.arguments = []
        try Settings.shared.saveCustomTools([folderTool])
        let large = CustomToolContext(
            folder: scratch.url, items: Array(repeating: FileItem(url: scratch.path("item"), name: "item", isDirectory: false), count: 101))
        #expect(throws: (any Error).self) { try runner.start(id: folderTool.id, context: large) }
        #expect(runner.runs.isEmpty)
    }
    @Test(.isolatedSettings) func importingCommandShortcutsCannotStealAToolBinding() throws {
        var tool = CustomToolDocument.examples[0]
        tool.shortcut = KeyboardShortcut(key: "9", modifiers: [.command, .option])
        try Settings.shared.saveCustomTools([tool])
        var preferences = ShortcutPreferences()
        preferences.overrides["other"] = tool.shortcut
        #expect(throws: (any Error).self) {
            try Settings.shared.importKeyboardShortcuts(preferences.encoded(), actions: [ShortcutAction(id: "other", title: "Other", defaults: [])])
        }
        #expect(Settings.shared.keyboardShortcuts.overrides.isEmpty)
    }
    @Test(.isolatedSettings) func literalArgumentsCurrentFolderOutputAndNonzeroExit() async throws {
        let scratch = try Scratch()
        let names = ["a b", "quote'\"", "line\nbreak", "日本語 🐬", "$(touch INJECTED)", "`touch INJECTED`", "{folder}", "-x"]
        let tool = CustomTool(name: "Arguments", executable: "/usr/bin/printf", arguments: ["<%s>\n", "{selection}"])
        var pwd = CustomTool(name: "Folder", executable: "/bin/pwd", arguments: []); pwd.selection = .folder
        var fail = CustomTool(name: "Fail", executable: "/usr/bin/false", arguments: []); fail.selection = .folder
        try Settings.shared.saveCustomTools([tool, pwd, fail])
        let runner = CustomToolRunner(), c = context(scratch, names: names)
        let run = try runner.start(id: tool.id, context: c)
        #expect(await eventually { !run.isRunning })
        #expect(run.exitStatus == 0)
        #expect(run.output == names.map { "<" + scratch.path($0).path + ">\n" }.joined())
        #expect(!FileManager.default.fileExists(atPath: scratch.path("INJECTED").path))
        let folderRun = try runner.start(id: pwd.id, context: c)
        #expect(await eventually { !folderRun.isRunning })
        let actual = try FileManager.default.attributesOfItem(atPath: folderRun.output.trimmingCharacters(in: .newlines))
        let expected = try FileManager.default.attributesOfItem(atPath: scratch.url.path)
        #expect(actual[.systemFileNumber] as? NSNumber == expected[.systemFileNumber] as? NSNumber)
        #expect(actual[.systemNumber] as? NSNumber == expected[.systemNumber] as? NSNumber)
        let failed = try runner.start(id: fail.id, context: c)
        #expect(await eventually { !failed.isRunning })
        #expect(failed.exitStatus == 1); #expect(failed.status == "Exit 1")
        runner.clearFinished(); #expect(runner.runs.isEmpty)
    }
    @Test(.isolatedSettings) func launchFailurePermissionsAndBoundedOutput() async throws {
        let scratch = try Scratch()
        let denied = try scratch.file("not executable", "hello")
        var bad = CustomTool(name: "Denied", executable: denied.path, arguments: []); bad.selection = .folder
        var missing = bad; missing.id = UUID(); missing.executable = scratch.path("missing").path
        var output = CustomTool(name: "Output", executable: "/usr/bin/head", arguments: ["-c", "1200000", "/dev/zero"]); output.selection = .folder
        try Settings.shared.saveCustomTools([bad, missing, output])
        let runner = CustomToolRunner()
        for tool in [bad, missing] {
            let run = try runner.start(id: tool.id, context: context(scratch))
            #expect(await eventually { !run.isRunning }); #expect(run.failure != nil); #expect(run.exitStatus == nil)
            #expect(!run.status.contains(scratch.url.path))
        }
        let run = try runner.start(id: output.id, context: context(scratch))
        #expect(await eventually { !run.isRunning })
        #expect(run.output.hasSuffix("[Output limited to 1 MiB]")); #expect(run.output.utf8.count < 1_049_000)
    }
    @Test(.isolatedSettings) func cancellationAndConcurrencyLimit() async throws {
        let scratch = try Scratch()
        var tool = CustomTool(name: "Sleep", executable: "/bin/sleep", arguments: ["30"]); tool.selection = .folder
        try Settings.shared.saveCustomTools([tool])
        let runner = CustomToolRunner()
        let runs = try (0..<4).map { _ in try runner.start(id: tool.id, context: context(scratch)) }
        defer { runs.forEach { $0.cancel() } }
        #expect(throws: (any Error).self) { try runner.start(id: tool.id, context: context(scratch)) }
        for run in runs { run.cancel() }
        #expect(await eventually { runs.allSatisfy { !$0.isRunning } })
        #expect(runs.allSatisfy { $0.cancelled })
    }
    @Test(.isolatedSettings) func stderrIsCapturedAndOutputArrivesBeforeExit() async throws {
        let scratch = try Scratch()
        // User-authored script is fixed here; none of the selected names enters shell source.
        var tool = CustomTool(
            name: "Stream", executable: "/bin/sh", arguments: ["-c", "printf first; printf error >&2; sleep 1; printf last; exit 7"])
        tool.selection = .folder
        try Settings.shared.saveCustomTools([tool])
        let run = try CustomToolRunner().start(id: tool.id, context: context(scratch))
        #expect(await eventually { run.output.contains("first") && run.isRunning })
        #expect(await eventually { !run.isRunning })
        #expect(run.output == "firsterrorlast"); #expect(run.exitStatus == 7)
    }
}
