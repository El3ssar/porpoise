import Darwin
import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseFileSystem

@Suite struct FinderIconMetadataTests {
    @Test func batchedAndPosixFallbackMatchForEveryField() throws {
        let scratch = try Scratch()
        let root = scratch.url
        let regular = root.appendingPathComponent("plain.pdf")
        try Data("demo".utf8).write(to: regular)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: regular.path)
        let hard = root.appendingPathComponent("hard.pdf")
        try FileManager.default.linkItem(at: regular, to: hard)
        let link = root.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        let broken = root.appendingPathComponent("broken.pdf")
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: root.appendingPathComponent("absent"))
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let denied = root.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        let child = denied.appendingPathComponent("child.pdf")
        try Data().write(to: child)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        for url in [regular, hard, link, broken, folder, denied, child] {
            guard let values = try? url.resourceValues(forKeys: FileItem.resourceKeySet) else {
                #expect(FileItem.load(url) == nil)
                continue
            }
            let batched = FileItem.load(url, values: values)
            // A filesystem rejecting Finder attributes takes this same branch.
            let fallback = FileItem.load(url, values: values, finderMetadata: { _ in nil })
            #expect(batched == fallback, "Every FileItem field must match: \(url.lastPathComponent)")
            #expect(batched?.hasCustomIcon == false)
        }
        #expect(FileItem.load(regular)?.posixPermissions == 0o640)
        #expect(FileItem.load(link)?.posixPermissions == 0o755)
        #expect(FileItem.load(link)?.isSymlink == true)
        #expect(FileItem.load(broken)?.isSymlink == true)
        #expect(FileItem.load(hard)?.size == FileItem.load(regular)?.size)
        #expect(FileItem.load(denied)?.posixPermissions == 0)
    }

    @Test func finderCustomFlagIsBigEndianAndNoFollow() throws {
        let scratch = try Scratch()
        let url = scratch.url.appendingPathComponent("custom.pdf")
        try Data().write(to: url)
        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x04
        #expect(setxattr(url.path, "com.apple.FinderInfo", &info, info.count, 0, 0) == 0)
        let values = try url.resourceValues(forKeys: FileItem.resourceKeySet)
        #expect(FileItem.load(url, values: values)?.hasCustomIcon == true)
        #expect(FileItem.load(url, values: values, finderMetadata: { _ in nil })?.hasCustomIcon == true)
        let link = scratch.url.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(FileItem.load(link)?.hasCustomIcon == false)
    }
}
