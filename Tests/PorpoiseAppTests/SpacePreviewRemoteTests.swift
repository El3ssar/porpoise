import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

@Suite(.serialized, .isolatedSettings) @MainActor struct SpacePreviewRemoteTests {
    @Test func progressiveTextKeepsItsGlassAndSelectionCancelsLateContent() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let prefix = try scratch.file("prefix.swift", "let first = 1"), full = try scratch.file("full.swift", "let complete = 2")
        let current = try scratch.file("current.py", "def current(): return 3")
        let root = URL(string: "gdrive://\(UUID().uuidString)/")!
        let provider = PreviewProvider(prefix: prefix, full: full)
        RemoteFS.registerCloud(provider, for: root)
        defer { RemoteFS.registerCloud(nil, for: root); provider.release() }
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let panel = SpacePreviewPanel()
        defer { panel.close(); parent.close() }
        let remote = FileItem(
            url: root.appendingPathComponent("remote.swift"), name: "remote.swift", isDirectory: false, contentType: "public.swift-source")
        panel.show([remote], relativeTo: parent)
        try #require(await poll { panel.code.document?.text == "let first = 1" && !panel.code.isLoading })
        #expect(panel.contentView === panel.material && panel.backgroundColor == .clear && provider.progressiveCalls.value == 1)
        panel.show([try #require(FileItem.load(current))], relativeTo: parent)
        provider.release()
        try #require(await poll { panel.code.document?.language == .python && !panel.code.isLoading })
        #expect(panel.code.document?.text == "def current(): return 3")
        #expect(provider.fullPaints.value == 0 && provider.downloadCalls.value == 0)
    }

    @Test func failedAutomaticRemoteTextRestoresTheIcon() async throws {
        _ = NSApplication.shared
        Settings.shared.previewRemote = true
        Settings.shared.previewText = false
        Settings.shared.infoShowPreview = true
        let scratch = try Scratch()
        let local = try scratch.file("unused.swift", "let unused = 1")
        let root = URL(string: "gdrive://\(UUID().uuidString)/my-drive")!
        let item = FileItem(url: root.appendingPathComponent("missing.swift"), name: "missing.swift", isDirectory: false)
        let provider = PreviewProvider(prefix: local, full: local, listing: [item], failsPreview: true)
        RemoteFS.registerCloud(provider, for: root)
        defer { RemoteFS.registerCloud(nil, for: root) }
        let wc = MainWindowController(urls: [root])
        defer { wc.window?.close() }
        try #require(await poll { wc.view.model.rows.count == 1 })
        wc.view.list.select(item.url)
        let panel = InformationPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        panel.show(hovered: nil, container: wc.view)
        try #require(await poll { provider.progressiveCalls.value == 1 && panel.codePreview.isHidden })
        #expect(panel.subviews.contains { ($0 as? NSImageView)?.image != nil && !$0.isHidden })
        #expect(panel.codePreview.document == nil && provider.downloadCalls.value == 0)
    }

    @Test func cloudVideoUsesStreamingAndCloseStopsOwnedStream() async throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let local = try scratch.file("not-media.mov", "not a movie")
        let root = URL(string: "gdrive://\(UUID().uuidString)/")!
        let provider = PreviewProvider(prefix: local, full: local)
        RemoteFS.registerCloud(provider, for: root)
        defer { RemoteFS.registerCloud(nil, for: root) }
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let panel = SpacePreviewPanel()
        defer { panel.close(); parent.close() }
        panel.show(
            [
                FileItem(
                    url: root.appendingPathComponent("movie.mov"), name: "movie.mov", isDirectory: false, contentType: "com.apple.quicktime-movie")
            ], relativeTo: parent
        )
        try #require(await poll { provider.playbackCalls.value == 1 })
        #expect(provider.progressiveCalls.value == 0 && provider.downloadCalls.value == 0)
        panel.close()
        try #require(await poll { provider.stream.stops.value == 1 })
        #expect(panel.state == "empty" && panel.backgroundColor == .clear)
    }
}

private final class PreviewProvider: CloudFileProvider, @unchecked Sendable {
    let descriptor = CloudProvider.googleDrive.descriptor
    let prefix: URL
    let full: URL
    let listing: [FileItem]
    let failsPreview: Bool
    let progressiveCalls = Counter(), playbackCalls = Counter(), downloadCalls = Counter(), fullPaints = Counter()
    let stream: PreviewStream
    private let gate = Locked<Callback<Void>?>(nil)
    init(prefix: URL, full: URL, listing: [FileItem] = [], failsPreview: Bool = false) {
        self.prefix = prefix; self.full = full; self.listing = listing; self.failsPreview = failsPreview
        stream = PreviewStream(url: full)
    }
    func release() {
        gate.change { callback in
            callback?.resume(); callback = nil
        }
    }
    func progressivePreview(_ remote: URL, context: CloudTransferContext, onPreview: @escaping @MainActor (URL) async throws -> Void) async throws
        -> URL
    {
        progressiveCalls.add()
        if failsPreview { throw CocoaError(.fileReadNoSuchFile) }
        try await onPreview(prefix)
        try await awaitCallback { callback in gate.change { $0 = callback } }
        try Task.checkCancellation()
        fullPaints.add()
        try await onPreview(full)
        return full
    }
    func playback(_ url: URL) async throws -> CloudPlayback { playbackCalls.add(); return CloudPlayback(url: stream.url, stream: stream) }
    func preview(_ remote: URL, thumbnail: Bool) async throws -> URL { prefix }
    func cachedListing(_ folder: URL) -> [FileItem]? { listing }
    func refresh(_ folder: URL, onPage: @escaping @Sendable ([FileItem], Bool) async -> Void) async throws -> [FileItem] { listing }
    func prefetch(_ folders: [URL]) async {}
    func displayName(for url: URL) -> String? { nil }
    func transferItem(_ url: URL) throws -> FileItem { throw CocoaError(.featureUnsupported) }
    func list(_ folder: URL) throws -> [FileItem] { listing }
    func download(_ remote: URL, into localFolder: URL) throws -> URL { downloadCalls.add(); throw CocoaError(.featureUnsupported) }
    func upload(_ local: URL, into remoteFolder: URL) throws { throw CocoaError(.featureUnsupported) }
    func delete(_ remote: [URL]) throws { throw CocoaError(.featureUnsupported) }
    func makeFolder(_ remote: URL) throws { throw CocoaError(.featureUnsupported) }
    func rename(_ remote: URL, to newName: String) throws { throw CocoaError(.featureUnsupported) }
    func move(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    func copy(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    func rootTitle(_ url: URL) -> String { "Fixture" }
}

private final class PreviewStream: CloudPreviewStream {
    let url: URL
    let stops = Counter()
    init(url: URL) { self.url = url }
    func stop() { stops.add() }
}
