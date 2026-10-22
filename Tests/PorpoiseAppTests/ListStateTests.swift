import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

/// An empty list says why, once (not again in a message bar), with a status line and a way out of a failure.
@Suite(.serialized, .isolatedSettings) @MainActor struct ListStateTests {
    init() { _ = NSApplication.shared }

    private func loaded(_ url: URL) async -> ViewContainer {
        let pane = ViewContainer(url: url)
        pane.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        _ = await eventually { !pane.model.isLoading && pane.listState.state?.title != "Loading…" }
        pane.layoutSubtreeIfNeeded()
        return pane
    }

    @Test func emptyFolderSaysSoAndCountsNothing() async throws {
        let scratch = try Scratch()
        let pane = await loaded(scratch.url)
        #expect(pane.listState.state == ListState(title: "Folder is empty", symbol: "folder") && !pane.listState.isHidden)
        #expect(pane.statusBar.text == "0 items")
        #expect(pane.listState.frame == pane.scroll.frame)
        // Clicks on the empty space reach the list (its background menu, drops).
        #expect(pane.listState.hitTest(CGPoint(x: 5, y: 5)) == nil)
        try "x".write(to: scratch.url.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        pane.reload()
        _ = await eventually { pane.listState.state == nil }
        #expect(pane.listState.isHidden && pane.statusBar.text.hasPrefix("1 file"))
    }

    @Test func missingFolderOffersTheEnclosingOneWithoutAMessageBar() async throws {
        let scratch = try Scratch()
        let gone = scratch.url.appendingPathComponent("gone")
        let pane = await loaded(gone)
        let state = try #require(pane.listState.state)
        #expect(state.title == "Folder not found" && state.action == .goUp)
        #expect(pane.messageBar.isHidden && pane.statusBar.text == "Folder not found")
        pane.listState.performAction()
        _ = await eventually { pane.url.standardizedFileURL == scratch.url.standardizedFileURL }
        #expect(pane.url.standardizedFileURL == scratch.url.standardizedFileURL)
    }

    @Test func unreadableFolderSaysNoAccess() async throws {
        let scratch = try Scratch()
        let locked = scratch.url.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let pane = await loaded(locked)
        #expect(pane.listState.state?.title == "No access" && pane.listState.state?.action == .goUp)
        #expect(pane.messageBar.isHidden)
    }

    @Test func viewShowsDetailsOnlyOnRequestAndHidesForNothing() throws {
        let view = ListStateView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        var ran: ListState.Action?
        view.onAction = { ran = $0 }
        view.show(ListState(title: "Couldn’t connect", message: "It refused.", details: "raw words", action: .retry, isError: true))
        view.layoutSubtreeIfNeeded()
        let texts = view.descendants(of: NSTextField.self).filter { !$0.isHidden }.map(\.stringValue)
        #expect(texts.contains("Couldn’t connect") && texts.contains("It refused.") && !texts.contains("raw words"))
        let toggle = try #require(view.descendants(of: NSButton.self).first { $0.title == "Show Details" })
        toggle.performClick(nil)
        #expect(view.descendants(of: NSTextField.self).contains { !$0.isHidden && $0.stringValue == "raw words" })
        #expect(toggle.title == "Hide Details")
        let action = try #require(view.descendants(of: NSButton.self).first { $0.title == "Try Again" })
        action.performClick(nil)
        #expect(ran == .retry)
        view.show(nil)
        #expect(view.isHidden && view.state == nil)
    }
}

extension NSView {
    fileprivate func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + $0.descendants(of: type) }
    }
}
