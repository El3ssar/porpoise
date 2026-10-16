import Foundation
import PorpoiseCore
import Testing

@testable import PorpoiseServices

struct FileComparisonTests {
    @Test func streamingByteOffsetsAndMetadata() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a"), b = folder.appendingPathComponent("b")
        var data = Data(repeating: 65, count: (1 << 20) + 20)
        try data.write(to: a); try data.write(to: b)
        #expect(try FileComparison.firstDifference(a, b) == nil)
        data[(1 << 20) + 5] = 66; try data.write(to: b)
        #expect(try FileComparison.firstDifference(a, b) == UInt64((1 << 20) + 5))
        try Data("abc".utf8).write(to: a); try Data("abcd".utf8).write(to: b)
        #expect(try FileComparison.firstDifference(a, b) == 3)
        #expect(try ComparedFile(url: a, readText: true).text == "abc")
        try Data([0, 1, 2]).write(to: a)
        #expect(try ComparedFile(url: a, readText: true).text == nil)
        let token = DiskCancellation(); token.cancel()
        #expect(throws: CancellationError.self) { try FileComparison.firstDifference(a, b, cancellation: token) }
    }
}
