import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite(.isolatedSettings) struct FinderQuickActionsTests {
    @Test func filtersFileTypesAndApplicationContexts() throws {
        let scratch = try Scratch()
        try QuickActionFixture.make(in: scratch.url, name: "All")
        try QuickActionFixture.make(in: scratch.url, name: "Folders", types: ["public.folder"])
        try QuickActionFixture.make(in: scratch.url, name: "Images", types: ["public.image"], application: nil)
        try QuickActionFixture.make(in: scratch.url, name: "Other App", application: "com.apple.TextEdit")
        let text = try QuickActionFixture.make(in: scratch.url, name: "Text Only", types: [])
        try QuickActionFixture.write(
            [
                "NSServices": [["NSMessage": "runWorkflowAsService", "NSSendTypes": ["public.utf8-plain-text"]]]
            ], to: text.appendingPathComponent("Contents/Info.plist"))
        let service = FinderQuickActions(directories: [scratch.url])
        let image = FileItem(url: scratch.path("a.png"), name: "a.png", isDirectory: false)
        let folder = FileItem(url: scratch.path("Folder"), name: "Folder", isDirectory: true)
        let unknown = FileItem(url: scratch.path("file"), name: "file", isDirectory: false)
        #expect(service.actions(for: [image]).map(\.name) == ["All", "Images"])
        #expect(service.actions(for: [folder]).map(\.name) == ["All", "Folders"])
        #expect(service.actions(for: [image, folder]).map(\.name) == ["All"])
        #expect(service.actions(for: [unknown]).map(\.name) == ["All"])
        #expect(service.actions(for: []).isEmpty)
        let remote = FileItem(url: URL(string: "sftp://example.com/a.png")!, name: "a.png", isDirectory: false)
        #expect(service.actions(for: [image, remote]).isEmpty)
        #expect(FinderQuickActions().actions(for: [image]).isEmpty)
    }

    @Test func localizesNamesPrefersUserWorkflowAndReloadsChanges() throws {
        let scratch = try Scratch(), user = try scratch.folder("User"), system = try scratch.folder("System")
        let workflow = try QuickActionFixture.make(in: user, name: "Same", titles: ["default": "Default", "fr": "Français"])
        try QuickActionFixture.make(in: system, name: "Same", titles: ["default": "System"])
        try QuickActionFixture.make(in: system, name: "Other")
        let service = FinderQuickActions(directories: [user, system], languages: ["fr-FR"])
        let item = FileItem(url: scratch.path("a.txt"), name: "a.txt", isDirectory: false)
        #expect(service.actions(for: [item]).map(\.name) == ["Français", "Other"])
        let english = FinderQuickActions(directories: [user], languages: ["en-US"])
        #expect(english.actions(for: [item]).map(\.name) == ["Default"])
        try FileManager.default.removeItem(at: workflow)
        #expect(service.actions(for: [item]).map(\.name) == ["Other", "System"])
        try scratch.file("User/Broken.workflow", "invalid")
        #expect(service.actions(for: [item]).count == 2)
    }

    @Test func respectsContextMenuDefaultsAndSavedChoices() async throws {
        let scratch = try Scratch()
        let hidden = try QuickActionFixture.make(in: scratch.url, name: "Hidden")
        try QuickActionFixture.make(in: scratch.url, name: "Visible")
        try QuickActionFixture.write(
            [
                "CFBundleIdentifier": "test.hidden",
                "NSServices": [["NSMenuItem": ["default": "Hidden"], "NSMessage": "runWorkflowAsService", "NSSendFileTypes": ["public.item"]]],
            ], to: hidden.appendingPathComponent("Contents/Info.plist"))
        let item = FileItem(url: scratch.path("file"), name: "file", isDirectory: false)
        let defaults = FinderQuickActions(directories: [scratch.url])
        #expect(defaults.actions(for: [item]).map(\.name) == ["Visible"])
        let states = FinderQuickActions.contextMenuStates(in: [
            "test.hidden - Hidden - runWorkflowAsService": ["presentation_modes": ["ContextMenu": true, "ServicesMenu": false]],
            "(null) - Visible - runWorkflowAsService": ["presentation_modes": ["ContextMenu": false], "enabled_context_menu": true],
            "Legacy": ["enabled_context_menu": false],
            "Unrelated": ["presentation_modes": ["ServicesMenu": true]],
        ])
        #expect(states["Legacy"] == false)
        #expect(states["Unrelated"] == nil)
        let configured = FinderQuickActions(directories: [scratch.url], contextMenuStates: states)
        #expect(configured.actions(for: [item]).map(\.name) == ["Hidden"])
        let visible = try #require(defaults.actions(for: [item]).first)
        await #expect(throws: (any Error).self) { try await configured.run(visible, on: [item]) }
    }

    @Test func readsWorkflowIconResources() throws {
        let scratch = try Scratch()
        let workflow = try QuickActionFixture.make(in: scratch.url, iconName: "CustomTemplate")
        let resources = workflow.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let bytes = Data([1, 2, 3])
        try bytes.write(to: resources.appendingPathComponent("CustomTemplate.png"))
        let item = FileItem(url: scratch.path("file"), name: "file", isDirectory: false)
        let action = try #require(FinderQuickActions(directories: [scratch.url]).actions(for: [item]).first)
        #expect(action.iconName == "CustomTemplate")
        #expect(action.iconData == bytes)
    }

    @Test func acceptsFilePasteboardServicesAndContextAlternatives() throws {
        let scratch = try Scratch()
        let workflow = try QuickActionFixture.make(in: scratch.url)
        try QuickActionFixture.write(
            [
                "NSServices": [
                    [
                        "NSMessage": "runWorkflowAsService", "NSSendTypes": ["NSFilenamesPboardType"],
                        "NSRequiredContext": [["NSApplicationIdentifier": "com.apple.TextEdit"], ["NSApplicationIdentifier": "com.apple.finder"]],
                    ]
                ]
            ], to: workflow.appendingPathComponent("Contents/Info.plist"))
        let item = FileItem(url: scratch.path("file"), name: "file", isDirectory: false)
        #expect(FinderQuickActions(directories: [scratch.url]).actions(for: [item]).map(\.name) == ["Record"])
        try QuickActionFixture.write(
            [
                "NSServices": [
                    [
                        "NSMessage": "runWorkflowAsService", "NSSendFileTypes": ["public.item"],
                        "NSRequiredContext": ["NSApplicationIdentifier": ["com.apple.TextEdit", "com.apple.finder"]],
                    ]
                ]
            ], to: workflow.appendingPathComponent("Contents/Info.plist"))
        #expect(FinderQuickActions(directories: [scratch.url]).actions(for: [item]).count == 1)
    }

    @Test func readsTheServicesMenuTranslation() throws {
        let scratch = try Scratch()
        let workflow = try QuickActionFixture.make(in: scratch.url)
        let localization = workflow.appendingPathComponent("Contents/Resources/fr.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: localization, withIntermediateDirectories: true)
        try QuickActionFixture.write(["Record": "Enregistrer"], to: localization.appendingPathComponent("ServicesMenu.strings"))
        let item = FileItem(url: scratch.path("file"), name: "file", isDirectory: false)
        #expect(FinderQuickActions(directories: [scratch.url], languages: ["fr-FR"]).actions(for: [item]).map(\.name) == ["Enregistrer"])
    }

    @Test(arguments: [false, true]) func runsInstalledWorkflowWithExactPaths(resourceDocument: Bool) async throws {
        let scratch = try Scratch(), services = try scratch.folder("Services"), output = scratch.path("received.bin")
        let workflow = try QuickActionFixture.make(in: services, script: QuickActionFixture.recordScript(to: output))
        if resourceDocument {
            let resources = workflow.appendingPathComponent("Contents/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.moveItem(
                at: workflow.appendingPathComponent("Contents/document.wflow"), to: resources.appendingPathComponent("document.wflow"))
        }
        let names = ["file name.txt", "quote's.txt", "日本語 $(touch injected).txt", "-option"]
        let files = try names.map { name in FileItem(url: try scratch.file(name), name: name, isDirectory: false) }
        let service = FinderQuickActions(directories: [services])
        let action = try #require(service.actions(for: files).first)
        try await service.run(action, on: files)
        let data = try Data(contentsOf: output)
        #expect(data == Data((files.map { $0.url.path }.joined(separator: "\0") + "\0").utf8))
        #expect(!FileManager.default.fileExists(atPath: scratch.path("injected").path))
    }

    @Test func rejectsLineBreaksAndRemovedOrChangedWorkflows() async throws {
        let scratch = try Scratch(), output = scratch.path("not-run")
        let workflow = try QuickActionFixture.make(in: scratch.url, script: QuickActionFixture.recordScript(to: output))
        let item = FileItem(url: try scratch.file("normal.txt"), name: "normal.txt", isDirectory: false)
        let service = FinderQuickActions(directories: [scratch.url])
        let action = try #require(service.actions(for: [item]).first)
        let newline = FileItem(url: try scratch.file("line\nbreak.txt"), name: "line\nbreak.txt", isDirectory: false)
        #expect(FinderQuickActions.unavailableReason(for: [newline]) != nil)
        await #expect(throws: (any Error).self) { try await service.run(action, on: [newline]) }
        try QuickActionFixture.make(in: scratch.url, types: ["public.folder"])
        await #expect(throws: (any Error).self) { try await service.run(action, on: [item]) }
        try FileManager.default.removeItem(at: workflow)
        await #expect(throws: (any Error).self) { try await service.run(action, on: [item]) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func reportsWorkflowFailure() async throws {
        let scratch = try Scratch()
        try QuickActionFixture.make(in: scratch.url, script: "exit 7")
        let item = FileItem(url: try scratch.file("input.txt"), name: "input.txt", isDirectory: false)
        let service = FinderQuickActions(directories: [scratch.url])
        let action = try #require(service.actions(for: [item]).first)
        await #expect(throws: (any Error).self) { try await service.run(action, on: [item]) }
    }
}
