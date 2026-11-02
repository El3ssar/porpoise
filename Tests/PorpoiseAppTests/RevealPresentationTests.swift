import AppKit
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@MainActor @Suite(.serialized, .isolatedSettings) struct RevealPresentationTests {
    init() { _ = NSApplication.shared }

    @Test func finderRevealPresentsEveryFilesSelectionAcrossFolders() async throws {
        let scratch = try Scratch()
        let files = [try scratch.file("left/a.txt"), try scratch.file("left/b.txt"), try scratch.file("right/c.txt")]
        let delegate = AppDelegate()
        Settings.shared.singleWindow = false
        Settings.shared.confirmCloseTabs = false
        Settings.shared.confirmCloseTerminal = false
        defer {
            for controller in delegate.windows {
                controller.window?.close()
                delegate.windowClosed(controller)
            }
        }
        delegate.reveal(files)
        let controller = try #require(delegate.windows.first)
        #expect(delegate.windows.count == 1 && controller.tabs.count == 2)
        for index in controller.tabs.indices {
            controller.showTab(index)
            let pane = controller.view
            let expected = Set(files.filter { $0.deletingLastPathComponent() == pane.url })
            try #require(await eventually { !pane.model.isLoading && pane.model.selection == expected })
            #expect(!expected.isEmpty)
        }
        Settings.shared.singleWindow = true
        delegate.reveal(Array(files.prefix(2)))
        #expect(delegate.windows.count == 1 && controller.tabs.count == 3)
        try #require(await eventually { !controller.view.model.isLoading && controller.view.model.selection == Set(files.prefix(2)) })
    }
}
