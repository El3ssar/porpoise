import AppIntents
import AppKit
import Foundation
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@MainActor @Suite(.serialized, .isolatedSettings) struct AutomationAppTests {
    init() { _ = NSApplication.shared }

    @Test func opensTabsSplitsAndRevealsLiteralSelection() async throws {
        let scratch = try Scratch()
        let left = try scratch.folder("Left"), right = try scratch.folder("Right")
        let paths = [try scratch.file("Left/quote'\".txt"), try scratch.file("Left/日本語\n.txt")]
        let wc = MainWindowController(urls: [scratch.url])
        defer { wc.window?.close() }
        let app = AppAutomation(windowProvider: { wc }, approval: { _, _, _, _, _ in true })
        let open = await app.handle(.init(action: .open, paths: [left.path]))
        #expect(open.error == nil && wc.view.url.path == left.path)
        let split = await app.handle(.init(action: .split, paths: [left.path, right.path]))
        #expect(split.error == nil && wc.tab.isSplit)
        #expect(wc.tab.inactive?.url.path == right.path)
        let reveal = await app.handle(.init(action: .reveal, paths: paths.map(\.path)))
        #expect(reveal.error == nil)
        #expect(await eventually { !wc.view.model.isLoading && wc.view.model.selection == Set(paths) })
        let selection = await app.handle(.init(action: .selection))
        #expect(Set(selection.paths) == Set(paths.map(\.path)))
    }

    @Test func queuedTransfersUseActivityAndExpiredRequestsDoNothing() async throws {
        let scratch = try Scratch()
        let source = try scratch.file("$(touch INJECTED) 'quote\n.txt")
        let copied = try scratch.folder("copy"), moved = try scratch.folder("move")
        let wc = MainWindowController(urls: [scratch.url])
        defer { wc.window?.close() }
        let app = AppAutomation(windowProvider: { wc }, approval: { _, _, _, _, _ in true })
        let before = FileOperationsController.shared.activities.count
        let expired = await app.handle(.init(action: .move, paths: [source.path], destination: moved.path), deadline: .distantPast)
        #expect(expired.error != nil)
        #expect(FileOperationsController.shared.activities.count == before)
        let copy = await app.handle(.init(action: .copy, paths: [source.path], destination: copied.path))
        #expect(copy.error == nil && copy.message == "Queued in Activity; awaiting approval in Porpoise.")
        let copiedFile = copied.appendingPathComponent(source.lastPathComponent)
        #expect(await eventually { FileManager.default.fileExists(atPath: copiedFile.path) })
        #expect(FileOperationsController.shared.activities.contains { $0.sources == [source] && $0.destination?.path == copied.path })
        let move = await app.handle(.init(action: .move, paths: [source.path], destination: moved.path))
        #expect(move.error == nil)
        #expect(
            await eventually {
                FileManager.default.fileExists(atPath: moved.appendingPathComponent(source.lastPathComponent).path)
                    && !FileManager.default.fileExists(atPath: source.path)
            })
        #expect(!FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("INJECTED").path))
    }

    @Test func rejectsBadLocationsAndExternalToolRequests() async throws {
        let scratch = try Scratch()
        let file = try scratch.file("file")
        let wc = MainWindowController(urls: [scratch.url])
        defer { wc.window?.close() }
        let app = AppAutomation(windowProvider: { wc }, approval: { _, _, _, _, _ in true })
        for request in [
            AutomationRequest(action: .open, paths: [file.path]), .init(action: .open, paths: ["relative"]),
            .init(action: .runTool, toolID: UUID()), .init(action: .open, paths: ["/nonexistent/porpoise-automation"]),
        ] {
            let response = await app.handle(request)
            #expect(response.error != nil)
            #expect(!response.error!.contains("nonexistent"))
        }
    }

    @Test func everyTransferRequiresApprovalAndSocketConsent() async throws {
        let scratch = try Scratch(), source = try scratch.file("source"), destination = try scratch.folder("destination")
        let wc = MainWindowController(urls: [scratch.url]); wc.showWindow(nil)
        defer { wc.window?.close() }
        var calls = 0
        let app = AppAutomation(
            windowProvider: { wc },
            approval: { paths, folder, action, _, _ in
                calls += 1
                #expect(paths.map(\.path) == [source.path] && folder.path == destination.path && action == .copy)
                return false
            })
        let request = AutomationRequest(action: .copy, paths: [source.path], destination: destination.path)
        let declined = await app.handle(request)
        #expect(declined.error == nil)
        #expect(await eventually { calls == 1 })
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("source").path))
        Settings.shared.allowCommandLineControl = false
        let disabled = await app.handle(.init(action: .selection), commandLine: true)
        #expect(disabled.error != nil)
        let approval = Task {
            await AppAutomation.confirmTransfer(
                [source], destination: destination, action: .copy, window: wc.window, deadline: Date().addingTimeInterval(2))
        }
        #expect(await eventually { wc.window?.attachedSheet != nil })
        let sheet = try #require(wc.window?.attachedSheet)
        #expect(sheet.defaultButtonCell?.title == "Cancel")
        wc.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        #expect(await approval.value == false)
    }

    @Test func intentsUseCurrentAppAndSavedTools() async throws {
        let savedApproval = AppAutomation.shared.approveTransfer
        AppAutomation.shared.approveTransfer = { _, _, _, _, _ in true }
        defer { AppAutomation.shared.approveTransfer = savedApproval }
        let scratch = try Scratch()
        let folder = try scratch.folder("Folder")
        let file = try scratch.file("Folder/日本語 'quote\n.txt")
        AppDelegate.shared.newWindow(at: scratch.url)
        let wc = try #require(AppDelegate.shared.windows.last)
        defer { wc.window?.close() }
        let open = OpenPorpoiseLocationIntent(); open.path = folder.path
        _ = try await open.perform()
        #expect(wc.view.url.path == folder.path)
        let reveal = RevealInPorpoiseIntent(); reveal.paths = [file.path]
        _ = try await reveal.perform()
        #expect(await eventually { wc.view.model.selection.contains(file) })
        let selection = try await GetPorpoiseSelectionIntent().perform()
        #expect(selection.value == [file.path])
        let tool = CustomTool(name: "Literal", executable: "/usr/bin/printf", arguments: ["%s", "{selection}"])
        try Settings.shared.saveCustomTools([tool])
        let entities = try await PorpoiseToolQuery().suggestedEntities()
        #expect(entities.map(\.id) == [tool.id])
        let run = RunPorpoiseCustomToolIntent(); run.tool = try #require(entities.first)
        _ = try await run.perform()
        let activity = try #require(CustomToolRunner.shared.runs.first)
        #expect(await eventually { !activity.isRunning })
        #expect(activity.output == file.path && activity.exitStatus == 0)
        let copied = try scratch.folder("Copied"), moved = try scratch.folder("Moved")
        let copy = CopyWithPorpoiseIntent()
        copy.paths = [file.path]; copy.useSelection = false; copy.destination = copied.path
        _ = try await copy.perform()
        #expect(await eventually { FileManager.default.fileExists(atPath: copied.appendingPathComponent(file.lastPathComponent).path) })
        let move = MoveWithPorpoiseIntent()
        move.useSelection = true; move.destination = moved.path
        _ = try await move.perform()
        #expect(await eventually { FileManager.default.fileExists(atPath: moved.appendingPathComponent(file.lastPathComponent).path) })
        try Settings.shared.saveCustomTools([])
        await #expect(throws: (any Error).self) { _ = try await run.perform() }
    }
}
