import AppKit
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import Porpoise
@testable import PorpoiseServices

@Suite(.serialized, .isolatedSettings) @MainActor struct ThumbnailReturnTests {
    private final class Owner: ThumbnailOwner {
        var shown: Set<URL> = []
        func showsThumbnail(of url: URL) -> Bool { shown.contains(url) }
    }

    @Test(arguments: ["file", "folder", "another-owner"])
    func returningBeforeCancelledDownloadFinishesRetriesFromItsCompletion(_ target: String) async throws {
        _ = NSApplication.shared
        Settings.shared.previewRemote = true
        let root = URL(string: "sftp://return-\(UUID().uuidString.lowercased()).invalid/")!
        let server = GatedServer(png: ThumbnailSchedulingTests.png)
        RemoteFS.use(server, for: root)
        defer { server.open(); RemoteFS.use(nil, for: root) }
        let item = FileItem(url: root.appendingPathComponent("folder/image.png"), name: "image.png", isDirectory: false, size: 100)
        let thumbnails = Thumbnails()
        let initial = Owner(), returning = target == "another-owner" ? Owner() : initial
        let firstTarget = target == "folder" ? root.appendingPathComponent("folder") : item.url
        let returnedTarget = target == "another-owner" ? item.url.deletingLastPathComponent() : firstTarget
        initial.shown = [firstTarget]
        var shown: NSImage?
        var notifications: [URL] = []
        let observer = NotificationCenter.default.addObserver(forName: Thumbnails.ready, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let url = note.object as? URL, url.absoluteString.hasPrefix(root.absoluteString) else { return }
                notifications.append(url)
                if notifications.count == 1 {
                    // The first event is a retry invalidation, never publication of the cancelled image.
                    #expect(url == returnedTarget && thumbnails.outstanding == 0)
                    #expect(thumbnails.scheduler.runningCount(.server) == 0)
                    #expect(server.copies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
                }
                if url == returnedTarget || url == item.url {
                    shown = thumbnails.thumbnail(for: item, size: 64, owner: returning, shownAs: returnedTarget)
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(thumbnails.thumbnail(for: item, size: 64, owner: initial, shownAs: firstTarget) == nil)
        await expectEventually { server.started == 1 }
        initial.shown = []
        thumbnails.scheduler.reconcile()
        returning.shown = [returnedTarget]
        #expect(thumbnails.thumbnail(for: item, size: 64, owner: returning, shownAs: returnedTarget) == nil)
        #expect(server.started == 1 && thumbnails.outstanding == 1 && notifications.isEmpty)
        server.open()
        await expectEventually { thumbnails.outstanding == 0 }
        // No external repaint or polling thumbnail(for:) is needed after the owner returns.
        #expect(server.started == 2 && shown != nil)
        #expect(notifications.first == returnedTarget && notifications.last == item.url)
        #expect(notifications.count == 2 && !thumbnails.hasFailed(item, 64))
    }

    @Test func cancelledDownloadsWithoutAWantedOwnerDoNotNotifyOrRetry() async throws {
        _ = NSApplication.shared
        Settings.shared.previewRemote = true
        let root = URL(string: "sftp://gone-\(UUID().uuidString.lowercased()).invalid/")!
        let server = GatedServer(png: ThumbnailSchedulingTests.png)
        RemoteFS.use(server, for: root)
        defer { server.open(); RemoteFS.use(nil, for: root) }
        let item = FileItem(url: root.appendingPathComponent("image.png"), name: "image.png", isDirectory: false, size: 100)
        let thumbnails = Thumbnails(), owner = Owner()
        owner.shown = [item.url]
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: Thumbnails.ready, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { if note.object as? URL == item.url { notifications += 1 } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = thumbnails.thumbnail(for: item, size: 64, owner: owner)
        await expectEventually { server.started == 1 }
        owner.shown = []
        thumbnails.scheduler.reconcile()
        server.open()
        await expectEventually { thumbnails.outstanding == 0 }
        #expect(server.started == 1 && notifications == 0 && !thumbnails.hasFailed(item, 64))
    }
}
