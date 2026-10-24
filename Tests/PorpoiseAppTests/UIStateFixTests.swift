import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

/// P11 UI-state fixes (CR-13, CR-14, CR-15, CR-16, CR-25). Keys go through the window as real key events.
@MainActor @Suite(.serialized, .isolatedSettings) struct UIStateFixTests {
    private func key(_ c: String, code: UInt16, in w: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil,
                characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code))
    }

    /// CR-14: a disabled flat button does nothing from Space, Return or VoiceOver, and Tab skips it.
    @Test func aDisabledFlatButtonIgnoresKeysAndVoiceOver() throws {
        let saved = KeyboardAccess.isFull
        defer { KeyboardAccess.isFull = saved }
        KeyboardAccess.isFull = { true }
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        defer { w.close() }
        var presses = 0
        let b = FlatButton(icon: nil, title: "Up") { presses += 1 }
        b.frame = CGRect(x: 10, y: 10, width: 80, height: 30)
        w.contentView?.addSubview(b)
        w.orderFront(nil)
        #expect(w.makeFirstResponder(b))
        w.sendEvent(try key(" ", code: 49, in: w))
        #expect(presses == 1)

        b.isEnabled = false
        w.sendEvent(try key(" ", code: 49, in: w))
        w.sendEvent(try key("\r", code: 36, in: w))
        #expect(!b.accessibilityPerformPress())
        #expect(presses == 1)
        #expect(!b.canBecomeKeyView)
    }

    private func browser(_ urls: [URL]) throws -> MainWindowController {
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppDelegate.shared.newWindow(urls: urls)
        let wc = try #require(AppDelegate.shared.windows.last)
        wc.window?.orderFront(nil)
        return wc
    }

    private func close(_ wc: MainWindowController) {
        wc.window?.attachedSheet.map { wc.window?.endSheet($0) }
        wc.window?.close()
        AppDelegate.shared.windowClosed(wc)
    }

    /// CR-13: the rename of a new copy waits for a listing with it, and doesn't take focus that moved meanwhile.
    @Test func aDuplicateIsRenamedOnlyWhileItsListKeepsFocus() async throws {
        let s = try Scratch()
        let a = try s.file("a.txt", "a")
        let wc = try browser([s.url])
        defer { close(wc) }
        let w = try #require(wc.window), c = wc.view
        try #require(await eventually { !c.model.isLoading && c.model.rows.count == 1 })
        #expect(w.makeFirstResponder(c.list))
        c.list.select(a)
        wc.duplicateItem(nil)
        #expect(await eventually { c.model.rows.count == 2 && c.list.isRenaming })
        #expect(c.list.renamingItem?.url != a)
        c.list.cancelRename()

        // Focus moves on before the copy is listed: no rename editor turns up later.
        c.list.select(a)
        #expect(w.makeFirstResponder(c.list))
        wc.duplicateItem(nil)
        w.makeFirstResponder(nil)
        try #require(await eventually { c.model.rows.count == 3 })
        try await Task.sleep(for: .milliseconds(700))
        #expect(!c.list.isRenaming)
        #expect(!(w.firstResponder is NSText))

        // The pane goes elsewhere and back before the copy ends: no rename there either.
        let other = try s.folder("other")
        c.list.select(a)
        #expect(w.makeFirstResponder(c.list))
        wc.duplicateItem(nil)
        c.setURL(other)
        c.setURL(s.url)
        #expect(w.makeFirstResponder(c.list))
        try #require(await eventually { c.model.location.standardizedFileURL == s.url.standardizedFileURL && c.model.rows.count == 5 })
        try await Task.sleep(for: .milliseconds(700))
        #expect(!c.list.isRenaming)
    }

    /// CR-15: a link's folder opened in a new tab offers Add to Places there, and the old pane offers nothing later.
    @Test func aLinkFolderInANewTabOffersAddToPlacesThere() async throws {
        let s = try Scratch()
        let start = try s.folder("start"), linked = try s.folder("linked"), other = try s.folder("other")
        let link = "https://drive.google.com/drive/folders/CR15"
        let backend = CloudAccounts.shared.backend
        let demo = DemoCloudBackend(accounts: [CloudAccount(id: "cr15", email: "fixture@example.invalid", displayName: "Fixture")])
        demo.links[link] = .folder(linked)
        CloudAccounts.shared.backend = demo
        defer { CloudAccounts.shared.backend = backend }
        let wc = try browser([start])
        defer { close(wc) }
        let old = wc.view
        try #require(await eventually { !old.model.isLoading })
        wc.openCloudLink(try #require(URL(string: link)), in: old, newTab: true)
        let shown = wc.view
        #expect(shown !== old)
        #expect(await eventually { !shown.messageBar.isHidden && shown.messageBar.text.contains("from a link") })
        old.reload()
        try #require(await eventually { !old.model.isLoading })
        #expect(old.messageBar.isHidden || !old.messageBar.text.contains("from a link"))

        // In place, but the pane goes elsewhere before the folder is listed: no offer on that other folder.
        wc.openCloudLink(try #require(URL(string: link)), in: old, newTab: false)
        old.setURL(other)
        try #require(await eventually { old.model.location.standardizedFileURL == other.standardizedFileURL && !old.model.isLoading })
        try await Task.sleep(for: .milliseconds(200))
        #expect(old.messageBar.isHidden || !old.messageBar.text.contains("from a link"))
    }

    /// CR-16: a workspace that can't be opened leaves Recently Closed Tabs alone; one opened in a new window lists no
    /// Home tab there.
    @Test func workspacesRecordOnlyTabsTheyReplace() async throws {
        let s = try Scratch()
        let a = try s.folder("A"), b = try s.folder("B")
        let wc = try browser([a])
        defer { close(wc) }
        let before = wc.closedTabs.count
        var newer = WindowLayout(tabs: [TabLayout(primary: PaneLayout(url: b))])
        newer.version = WindowLayout.currentVersion + 1
        wc.open(Workspace(name: "Newer", layout: newer))
        #expect(wc.closedTabs.count == before)
        #expect(wc.tabs.count == 1 && wc.tabs[0].primary.url.standardizedFileURL == a.standardizedFileURL)
        wc.window?.attachedSheet.map { wc.window?.endSheet($0) }

        let saved = try #require(Settings.shared.saveWorkspace(named: "CR16", layout: WindowLayout(tabs: [TabLayout(primary: PaneLayout(url: b))])))
        defer { Settings.shared.deleteWorkspace(id: saved.id) }
        let item = NSMenuItem(title: "CR16", action: #selector(MainWindowController.openWorkspaceInNewWindow(_:)), keyEquivalent: "")
        item.representedObject = saved.id.uuidString
        let count = AppDelegate.shared.windows.count
        wc.openWorkspaceInNewWindow(item)
        let other = try #require(AppDelegate.shared.windows.last)
        defer { close(other) }
        #expect(AppDelegate.shared.windows.count == count + 1 && other !== wc)
        #expect(other.closedTabs.isEmpty)
        #expect(other.tabs.count == 1, "\(other.tabs.map(\.primary.url))")
        #expect(other.tabs.first?.primary.url.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path)
    }

    private final class EmptyFolder: RemoteProvider {
        func list(_ folder: URL) throws -> [FileItem] { [] }
        func rootTitle(_ url: URL) -> String { "Empty fixture" }
        func download(_ remote: URL, into localFolder: URL) throws -> URL { throw CocoaError(.featureUnsupported) }
        func upload(_ local: URL, into remoteFolder: URL) throws { throw CocoaError(.featureUnsupported) }
        func delete(_ remote: [URL]) throws { throw CocoaError(.featureUnsupported) }
        func makeFolder(_ remote: URL) throws { throw CocoaError(.featureUnsupported) }
        func rename(_ remote: URL, to newName: String) throws { throw CocoaError(.featureUnsupported) }
        func move(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
        func copy(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    }

    /// CR-25: Add to Places is available in an empty cloud folder, as the action supports.
    @Test func addToPlacesIsAvailableInAnEmptyCloudFolder() async throws {
        let account = "cr25-\(UUID().uuidString.prefix(6).lowercased())"
        let root = try #require(URL(string: "gdrive://\(account)/my-drive/"))
        let backend = CloudAccounts.shared.backend
        CloudAccounts.shared.backend = DemoCloudBackend(accounts: [
            CloudAccount(id: account, email: "fixture@example.invalid", displayName: "Fixture")
        ])
        RemoteFS.use(EmptyFolder(), for: root)
        defer {
            RemoteFS.use(nil, for: root)
            CloudAccounts.shared.backend = backend
        }
        let wc = try browser([root])
        defer { close(wc) }
        #expect(PlacesModel.isCloud(wc.view.url) && wc.view.model.selectedItems.isEmpty)
        #expect(wc.validateMenuItem(NSMenuItem(title: "Add to Places", action: #selector(MainWindowController.addToPlaces(_:)), keyEquivalent: "")))
    }
}
