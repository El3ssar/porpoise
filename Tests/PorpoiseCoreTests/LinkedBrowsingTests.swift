import Foundation
import Testing

@testable import PorpoiseCore

struct LinkedBrowsingTests {
    @Test func linkedNavigationUsesComponentBoundariesAndSameRemoteEndpoint() {
        let root = URL(fileURLWithPath: "/Projects")
        #expect(LinkedBrowsing.relativePath(root, below: root) == "")
        #expect(LinkedBrowsing.relativePath(root.appendingPathComponent("Invoices/2026"), below: root) == "Invoices/2026")
        #expect(LinkedBrowsing.relativePath(URL(fileURLWithPath: "/Projects-old/a"), below: root) == nil)
        #expect(LinkedBrowsing.relativePath(URL(fileURLWithPath: "/Projects/../outside"), below: root) == nil)
        #expect(LinkedBrowsing.relativePath(URL(string: "sftp://a/root/d")!, below: URL(string: "sftp://a/root")!) == "d")
        #expect(LinkedBrowsing.relativePath(URL(string: "sftp://b/root/d")!, below: URL(string: "sftp://a/root")!) == nil)
    }
    @Test func matchingFolderNamesUseDistinctAncestorLabels() {
        let names = LinkedBrowsing.sideNames(URL(fileURLWithPath: "/Home/Projects"), URL(fileURLWithPath: "/Backup/Projects"))
        #expect(names.0 == "Home"); #expect(names.1 == "Backup")
        let remote = LinkedBrowsing.sideNames(URL(fileURLWithPath: "/Home/Projects"), URL(string: "sftp://nas.local/Projects")!)
        #expect(remote.1 == "nas.local")
    }
    @Test func sideNamesUseNearestDistinctAncestorsAndHandleIdenticalRoots() {
        let a = URL(fileURLWithPath: "/home/Projects/Website"), b = URL(fileURLWithPath: "/backup/Projects/Website")
        let labels = LinkedBrowsing.sideNames(a, b)
        #expect(labels.0 == "home"); #expect(labels.1 == "backup")
        let same = LinkedBrowsing.sideNames(a, a)
        #expect(same.0 == "Website (left)"); #expect(same.1 == "Website (right)")
        let unequal = LinkedBrowsing.sideNames(a, URL(fileURLWithPath: "/backup"))
        #expect(unequal.0 == "Website"); #expect(unequal.1 == "backup")
        let root = LinkedBrowsing.sideNames(URL(fileURLWithPath: "/"), URL(string: "sftp://nas/")!)
        #expect(root.0 == "/"); #expect(root.1 == "nas")
    }
    @Test func linkedCounterpartsCoverEnterUpBackForwardBreadcrumbAndPathEdits() {
        let left = URL(fileURLWithPath: "/home/Projects"), right = URL(fileURLWithPath: "/backup/Projects")
        for path in ["Brand", "Brand/assets", "", "Website", "Brand"] {
            let source = path.isEmpty ? left : left.appendingPathComponent(path)
            let expected = path.isEmpty ? right : right.appendingPathComponent(path)
            #expect(LinkedBrowsing.counterpart(source, sourceRoot: left, targetRoot: right) == expected)
        }
        #expect(LinkedBrowsing.counterpart(left.deletingLastPathComponent(), sourceRoot: left, targetRoot: right)?.path == "/backup")
        #expect(LinkedBrowsing.counterpart(URL(fileURLWithPath: "/"), sourceRoot: left, targetRoot: right)?.path == "/")
        #expect(LinkedBrowsing.counterpart(URL(fileURLWithPath: "/unrelated"), sourceRoot: left, targetRoot: right) == nil)
        #expect(LinkedBrowsing.counterpart(URL(fileURLWithPath: "/"), sourceRoot: left, targetRoot: URL(fileURLWithPath: "/")) == nil)
        #expect(
            LinkedBrowsing.counterpart(URL(string: "sftp://host/root/child")!, sourceRoot: URL(string: "sftp://host/root")!, targetRoot: right)?.path
                == "/backup/Projects/child")
        #expect(
            LinkedBrowsing.counterpart(URL(string: "sftp://other/root/child")!, sourceRoot: URL(string: "sftp://host/root")!, targetRoot: right)
                == nil)
    }
}
