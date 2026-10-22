import Foundation
import Testing

@testable import PorpoiseCore

@Suite struct ColumnPathTests {
    @Test func localChainRunsFromTheRootDownToTheLocation() throws {
        let root = URL(fileURLWithPath: "/Users/me")
        let chain = try #require(ColumnPath.chain(from: root, to: URL(fileURLWithPath: "/Users/me/Documents/Letters")))
        #expect(chain.map(\.path) == ["/Users/me", "/Users/me/Documents", "/Users/me/Documents/Letters"])
        #expect(ColumnPath.chain(from: root, to: root)?.count == 1)
        // A trailing slash or a dot segment is the same folder.
        #expect(ColumnPath.chain(from: URL(fileURLWithPath: "/Users/me/"), to: URL(fileURLWithPath: "/Users/me/./Music"))?.count == 2)
    }

    @Test func foldersOutsideTheRootHaveNoChain() {
        let root = URL(fileURLWithPath: "/Users/me/Documents")
        #expect(ColumnPath.chain(from: root, to: URL(fileURLWithPath: "/Users/me")) == nil)
        #expect(ColumnPath.chain(from: root, to: URL(fileURLWithPath: "/Users/me/Downloads")) == nil)
        // A sibling whose name starts like the root's is not below it.
        #expect(!ColumnPath.contains(root, URL(fileURLWithPath: "/Users/me/Documents2/a")))
        #expect(ColumnPath.contains(root, URL(fileURLWithPath: "/Users/me/Documents/a")))
    }

    @Test func remoteChainsStayOnTheirServer() throws {
        let root = try #require(URL(string: "sftp://me@host:2222/home/me"))
        let deep = try #require(URL(string: "sftp://me@host:2222/home/me/src/app"))
        let chain = try #require(ColumnPath.chain(from: root, to: deep))
        #expect(chain.map(\.absoluteString) == ["sftp://me@host:2222/home/me", "sftp://me@host:2222/home/me/src/", "sftp://me@host:2222/home/me/src/app/"])
        #expect(chain.last?.path == "/home/me/src/app")
        #expect(ColumnPath.chain(from: root, to: URL(string: "sftp://me@other:2222/home/me/src")!) == nil)
        #expect(ColumnPath.chain(from: root, to: URL(string: "sftp://you@host:2222/home/me/src")!) == nil)
        #expect(ColumnPath.chain(from: root, to: URL(string: "ftp://me@host:2222/home/me/src")!) == nil)
        #expect(ColumnPath.chain(from: root, to: URL(fileURLWithPath: "/home/me/src")) == nil)
        // A server's root.
        let top = try #require(URL(string: "sftp://host/"))
        #expect(ColumnPath.chain(from: top, to: URL(string: "sftp://host/etc")!)?.count == 2)
    }
}
