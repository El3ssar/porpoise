import Darwin
import Foundation
import PorpoiseCore
import Testing

@testable import PorpoiseServices

struct CodePreviewLoaderTests {
    private func withFile(_ data: Data, _ body: (URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sample.swift")
        try data.write(to: file)
        try await body(file)
    }

    @Test @MainActor func callerOnMainGetsBoundedHighlightedText() async throws {
        try await withFile(Data("let café = 42\n".utf8)) { file in
            let document = try await CodePreviewLoader.load(file)
            #expect(document.text == "let café = 42\n")
            #expect(document.language == .swift && document.displayedLines == 1)
            #expect(!document.truncated && document.tokens.spans.contains { $0.kind == .keyword })
        }
    }

    @Test func byteAndLineCapsAreIndependent() async throws {
        try await withFile(Data(String(repeating: "let x = 1\r\n", count: 10000).utf8)) { file in
            let lines = try await CodePreviewLoader.load(file, limits: .init(lines: 3))
            #expect(lines.displayedLines == 3 && lines.truncated)
            #expect(lines.text == String(repeating: "let x = 1\r\n", count: 3))
            let bytes = try await CodePreviewLoader.load(file, limits: .init(bytes: 20))
            #expect(bytes.text.utf8.count <= 20 && bytes.truncated)
        }
        try await withFile(Data("one\ntwo\n".utf8)) { file in
            let exact = try await CodePreviewLoader.load(file, limits: .init(bytes: 8, lines: 2))
            #expect(!exact.truncated && exact.displayedLines == 2)
        }
    }

    @Test func unicodeBOMAndSplitScalars() async throws {
        for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
            let bom: [UInt8] = encoding == .utf8 ? [0xEF, 0xBB, 0xBF] : encoding == .utf16LittleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]
            let data = Data(bom) + "let 🐬 = 1\n".data(using: encoding)!
            try await withFile(data) { file in
                let full = try await CodePreviewLoader.load(file)
                #expect(full.text == "let 🐬 = 1\n" && !full.truncated)
                for cap in 7...12 {
                    let part = try await CodePreviewLoader.load(file, limits: .init(bytes: cap))
                    #expect(part.truncated && !part.text.contains("�"))
                }
            }
        }
    }

    @Test func rejectsBinaryInvalidAndNonregularFiles() async throws {
        for data in [Data([0, 1, 2]), Data([0xFF, 0xFF]), Data("abc\0def".utf8)] {
            try await withFile(data) { file in
                await #expect(throws: CodePreviewLoader.Failure.invalidText) { try await CodePreviewLoader.load(file) }
            }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: CodePreviewLoader.Failure.notRegularFile) { try await CodePreviewLoader.load(folder) }
        let fifo = folder.appendingPathComponent("fifo.swift")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        await #expect(throws: CodePreviewLoader.Failure.notRegularFile) { try await CodePreviewLoader.load(fifo) }
        await #expect(throws: CodePreviewLoader.Failure.notRegularFile) {
            try await CodePreviewLoader.load(URL(string: "https://invalid.test/a.swift")!)
        }
    }

    @Test func byteCapDoesNotHideMalformedText() async throws {
        for suffix: [UInt8] in [[0xFF], [0xC0], [0xE0, 0x80], [0xED, 0xA0], [0xF4, 0x90]] {
            let data = Data("valid".utf8) + Data(suffix) + Data([65])
            try await withFile(data) { file in
                await #expect(throws: CodePreviewLoader.Failure.invalidText) {
                    try await CodePreviewLoader.load(file, limits: .init(bytes: data.count - 1))
                }
            }
        }
    }

    @Test func emptySymlinkAndCancellation() async throws {
        try await withFile(Data()) { file in
            let link = file.deletingLastPathComponent().appendingPathComponent("link.swift")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            let empty = try await CodePreviewLoader.load(link)
            #expect(empty.text.isEmpty && empty.displayedLines == 0 && !empty.truncated)
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await CodePreviewLoader.load(file)
            }
            await #expect(throws: CancellationError.self) { try await cancelled.value }
        }
    }
}
