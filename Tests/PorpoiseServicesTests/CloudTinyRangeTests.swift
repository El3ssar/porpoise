import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

private struct TinyRangeRecord: CloudRangeDownloadRecord {
    var operationID: UUID
    var version = 1
    var offset: Int64 = 0
    var downloadRanges: [CloudDownloadRange]?
    var fingerprint: JobJournal.Fingerprint?
}

@Suite struct CloudTinyRangeTests {
    @Test func everyTinyPartitionCoversExactlyTheFile() async throws {
        for total in 1...17 {
            for connections in [1, 4, 8] {
                let scratch = try Scratch(), partial = try scratch.file("part", "")
                let data = Data((0..<total).map(UInt8.init))
                let record = TinyRangeRecord(operationID: UUID())
                let result = try await CloudRangeDownload.run(
                    total: Int64(total), partial: partial, record: record,
                    context: .init(), maximumConnections: connections, save: { _ in },
                    fetch: { range, receive in
                        #expect(!range.isEmpty && range.lowerBound >= 0 && range.upperBound <= total)
                        let response = HTTPURLResponse(
                            url: URL(string: "https://fixture.invalid")!, statusCode: 206,
                            httpVersion: nil, headerFields: ["Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)"])!
                        try await receive(data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)), response)
                        return response
                    })
                #expect(result.offset == total)
                #expect(try Data(contentsOf: partial) == data)
            }
        }
    }
}
