import Foundation
import PorpoiseCore
import Testing

@testable import PorpoiseServices

struct FileComparisonCopiesTests {
    @Test func remoteSnapshotsAreIsolatedAndNeverUpload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let remote = URL(string: "sftp://\(UUID().uuidString).invalid/report.txt")!, provider = ComparisonProvider()
        RemoteFS.use(provider, for: remote); defer { RemoteFS.use(nil, for: remote) }
        let a = try FileComparisonCopies(left: remote, right: remote, cacheParent: folder)
        let b = try FileComparisonCopies(left: remote, right: remote, cacheParent: folder)
        #expect(a.readOnly)
        #expect(a.left != a.right)
        #expect(a.left != b.left)
        #expect(try String(contentsOf: a.left, encoding: .utf8) == "remote contents")
        try "local edits".write(to: a.left, atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: b.left, encoding: .utf8) == "remote contents")
        #expect(provider.uploads == 0)
        let local = folder.appendingPathComponent("local.txt")
        try "local".write(to: local, atomically: true, encoding: .utf8)
        let pair = try FileComparisonCopies(left: local, right: local, cacheParent: folder)
        #expect(!pair.readOnly)
        #expect(pair.left == local)
        let token = DiskCancellation(); token.cancel()
        #expect(throws: CancellationError.self) { try FileComparisonCopies(left: remote, right: remote, cacheParent: folder, cancellation: token) }
    }
}

private final class ComparisonProvider: RemoteProvider {
    var uploads = 0
    func download(_ remote: URL, into localFolder: URL) throws -> URL {
        let url = localFolder.appendingPathComponent(remote.lastPathComponent)
        try "remote contents".write(to: url, atomically: true, encoding: .utf8); return url
    }
    func upload(_ local: URL, into remoteFolder: URL) throws { uploads += 1 }
    func list(_ folder: URL) throws -> [FileItem] { [] }
    func delete(_ remote: [URL]) throws { throw CocoaError(.featureUnsupported) }
    func makeFolder(_ remote: URL) throws { throw CocoaError(.featureUnsupported) }
    func rename(_ remote: URL, to newName: String) throws { throw CocoaError(.featureUnsupported) }
    func move(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    func copy(_ remote: [URL], into folder: URL) throws { throw CocoaError(.featureUnsupported) }
    func rootTitle(_ url: URL) -> String { "Test server" }
}
