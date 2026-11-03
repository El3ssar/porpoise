import AppKit
import PorpoiseCore
import PorpoiseServices
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise

@Suite(.serialized, .isolatedSettings) @MainActor struct ThumbnailVisibilityTests {
    private final class Owner: ThumbnailOwner {
        var wanted = true
        func showsThumbnail(of url: URL) -> Bool { wanted }
    }

    private func nextTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func visibilityChangesCancelWithoutAnyNewThumbnailRequest() async {
        let scheduler = ThumbnailWorkScheduler(limits: .init(active: [.video: 1], pending: 8))
        let owner = Owner()
        let url = URL(fileURLWithPath: "/fixture/movie.mkv")
        var active: ThumbnailWorkScheduler.Job?
        var cancelled = false, dropped = false
        scheduler.submit(
            "active", lane: .video, interest: .init(owner: owner, url: url),
            body: { job in
                active = job; job.onCancel { cancelled = true }
            }, dropped: {})
        scheduler.submit(
            "queued", lane: .video, interest: .init(owner: owner, url: url),
            body: { _ in Issue.record("obsolete queued thumbnail started") }, dropped: { dropped = true })
        defer { active?.finish() }
        await nextTurn()  // The original drawing pass's sweep has already finished.
        owner.wanted = false
        scheduler.requestReconcile()
        #expect(!cancelled && !dropped)  // Ownership updates finish before the coalesced sweep.
        await nextTurn()
        #expect(cancelled && dropped && scheduler.pendingCount == 0)
        #expect(scheduler.runningCount(.video) == 1)  // A cancelling job retains its slot until completion.
    }

    @Test func visibilitySweepPreservesOtherVisibleOwnersAndInspectorWork() async {
        let scheduler = ThumbnailWorkScheduler()
        let first = Owner(), second = Owner()
        let url = URL(fileURLWithPath: "/fixture/image.png")
        var active: [ThumbnailWorkScheduler.Job] = []
        var sharedCancelled = false, inspectorCancelled = false
        scheduler.submit(
            "shared", lane: .preview, interest: .init(owner: first, url: url),
            body: { job in
                active.append(job); job.onCancel { sharedCancelled = true }
            }, dropped: {})
        scheduler.touch("shared", interest: .init(owner: second, url: url))
        scheduler.submit(
            "inspector", lane: .preview, interest: .init(owner: nil, url: url),
            body: { job in
                active.append(job); job.onCancel { inspectorCancelled = true }
            }, dropped: {})
        defer { active.forEach { $0.finish() } }
        await nextTurn()
        first.wanted = false
        scheduler.requestReconcile()
        await nextTurn()
        #expect(!sharedCancelled && !inspectorCancelled)
        second.wanted = false
        scheduler.requestReconcile()
        await nextTurn()
        #expect(sharedCancelled && !inspectorCancelled)
    }

    @Test func transientOwnershipChangesAreResolvedAfterTheCurrentTurn() async {
        let scheduler = ThumbnailWorkScheduler()
        let owner = Owner()
        var active: ThumbnailWorkScheduler.Job?
        var cancelled = false
        scheduler.submit(
            "stays", lane: .preview, interest: .init(owner: owner, url: URL(fileURLWithPath: "/fixture/image.png")),
            body: { job in
                active = job; job.onCancel { cancelled = true }
            }, dropped: {})
        defer { active?.finish() }
        await nextTurn()
        owner.wanted = false
        scheduler.requestReconcile()
        scheduler.requestReconcile()
        owner.wanted = true
        await nextTurn()
        #expect(!cancelled)
    }

    @Test func anUnorderedOrDetachedWindowNeverOwnsThumbnailWork() throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let model = DirectoryModel(location: scratch.url, prefetchFolders: false)
        let item = FileItem(url: scratch.url.appendingPathComponent("image.png"), name: "image.png", isDirectory: false)
        model.searchResults = [item]
        let list = ItemListView(model: model)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        scroll.documentView = list
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        list.computeLayout()
        #expect(list.window === window && !window.isVisible && !window.isKeyWindow)
        #expect(!list.showsThumbnail(of: item.url))
        window.contentView = nil
        #expect(list.window == nil && !list.showsThumbnail(of: item.url))
    }

    @Test(arguments: ["hide", "detach", "close", "viewport", "occlusion", "settings", "layout"])
    func listLifecycleChangesSweepWithoutAnotherDrawingPass(_ event: String) async throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let list = ItemListView(model: DirectoryModel(location: scratch.url, prefetchFolders: false))
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        scroll.documentView = list
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        let owner = Owner()
        var active: ThumbnailWorkScheduler.Job?
        var cancelled = false
        let scheduler = Thumbnails.shared.scheduler
        scheduler.submit(
            "lifecycle-\(UUID().uuidString)", lane: .folder, interest: .init(owner: owner, url: scratch.url),
            body: { job in
                active = job; job.onCancel { cancelled = true }
            }, dropped: {})
        defer { active?.finish() }
        await nextTurn()
        owner.wanted = false
        switch event {
        case "hide": list.isHidden = true
        case "detach": window.contentView = nil
        case "close": window.close()
        case "viewport": NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        case "occlusion": NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        case "settings": Settings.shared.previewImages.toggle()
        case "layout": list.computeLayout()
        default: Issue.record("unknown lifecycle fixture")
        }
        #expect(!cancelled)
        await nextTurn()
        #expect(cancelled)
        #expect(!window.isVisible && !window.isKeyWindow)
    }
}
