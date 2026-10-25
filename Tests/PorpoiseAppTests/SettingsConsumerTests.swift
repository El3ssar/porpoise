import AppKit
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing
import os

@testable import Porpoise

@Suite(.serialized, .isolatedSettings) @MainActor struct SettingsConsumerTests {
    @Test func directoryGitObserverAcceptsOnlyItsKeyOrBroadcast() throws {
        Settings.store.set(false, forKey: "showGitStatus")
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url)
        let identity = ObjectIdentifier(model)
        let changes = OSAllocatedUnfairLock(initialState: 0)
        let center = NotificationCenter.default
        let token = center.addObserver(forName: DirectoryModel.gitStatusChanged, object: nil, queue: nil) { note in
            guard let sender = note.object as? DirectoryModel, ObjectIdentifier(sender) == identity else { return }
            changes.withLock { $0 += 1 }
        }
        defer { center.removeObserver(token) }
        for (payload, accepted): (Any?, Bool) in [
            (nil, true), ("showGitStatus", true), (NSString(string: "showGitStatus"), true),
            ("future.setting", false), ("", false), (42, false),
        ] {
            let before = changes.withLock { $0 }
            center.post(name: Settings.changed, object: payload)
            #expect(changes.withLock { $0 } == before + (accepted ? 1 : 0))
        }
    }

    @Test func paneTreatsMalformedPayloadAsBroadcastButIgnoresUnknownKeys() throws {
        _ = NSApplication.shared
        Settings.store.set(false, forKey: "showGitStatus")
        Settings.store.set(StatusBarMode.small.rawValue, forKey: "statusBar2")
        let scratch = try Scratch()
        let pane = ViewContainer(url: scratch.url)
        for (payload, refreshed): (Any?, Bool) in [
            (nil, true), ("statusBar2", true), (NSString(string: "statusBar2"), true),
            ("future.setting", false), ("", false), (42, true),
        ] {
            pane.statusBar.mode = .disabled
            NotificationCenter.default.post(name: Settings.changed, object: payload)
            #expect(pane.statusBar.mode == (refreshed ? .small : .disabled))
        }
    }

    @Test func toolbarFiltersPayloadsAndKeepsItsRefreshDeferred() async {
        _ = NSApplication.shared
        let toolbar = ToolbarView()
        for (payload, refreshed): (Any?, Bool) in [
            (nil, true), ("shortcutKeySet", true), ("keyboardShortcuts", true),
            (NSString(string: "keyboardShortcuts"), true), ("future.setting", false), ("", false), (42, false),
        ] {
            toolbar.back.toolTip = "unchanged sentinel"
            NotificationCenter.default.post(name: Settings.changed, object: payload)
            #expect(toolbar.back.toolTip == "unchanged sentinel")
            // The observer enqueues its refresh before this marker on the same main queue.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect((toolbar.back.toolTip != "unchanged sentinel") == refreshed)
        }
    }
}
