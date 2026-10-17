import Darwin
import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct FileComparisonTests {
    @Test func textReadReportsBytesAndSupportsCancellation() throws {
        let scratch = try Scratch(), url = scratch.path("file.txt")
        let data = Data(repeating: 65, count: 2 * 1024 * 1024 + 17)
        try data.write(to: url)
        var updates: [(UInt64, UInt64)] = []
        let file = try ComparedFile(url: url, readText: true, progress: { updates.append(($0, $1)) })
        #expect(file.text?.utf8.count == data.count)
        #expect(updates.last?.0 == UInt64(data.count))
        #expect(updates.allSatisfy { $0.0 <= $0.1 && $0.1 == UInt64(data.count) })
        let token = DiskCancellation()
        #expect(throws: CancellationError.self) {
            try ComparedFile(url: url, readText: true, cancellation: token, progress: { bytes, _ in if bytes > 0 { token.cancel() } })
        }
    }
    @Test func streamingByteOffsetsAndMetadata() throws {
        let scratch = try Scratch(), folder = scratch.url
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
        let attributeName = "com.porpoise.compare-test"
        let firstValue = Array("left".utf8), secondValue = Array("right".utf8)
        #expect(setxattr(a.path, attributeName, firstValue, firstValue.count, 0, 0) == 0)
        #expect(setxattr(b.path, attributeName, secondValue, secondValue.count, 0, 0) == 0)
        let leftAttributes = try ComparedFile(url: a, readText: false).attributes
        let rightAttributes = try ComparedFile(url: b, readText: false).attributes
        #expect(leftAttributes.contains { $0.hasPrefix(attributeName) })
        #expect(leftAttributes != rightAttributes)
        let token = DiskCancellation(); token.cancel()
        #expect(throws: CancellationError.self) { try FileComparison.firstDifference(a, b, cancellation: token) }
    }
}
