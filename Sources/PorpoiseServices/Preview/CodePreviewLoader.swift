import Darwin
import Foundation
import PorpoiseCore

/// Immutable, bounded text shared by Space, Information and Column previews.
public struct CodePreviewDocument: Sendable {
    public let text: String
    public let language: SyntaxLanguage
    public let tokens: SyntaxTokens
    public let displayedLines: Int
    public let truncated: Bool
}

public enum CodePreviewLoader {
    public struct Limits: Sendable {
        public let bytes: Int
        public let lines: Int
        public let tokens: Int
        public init(bytes: Int = 256 * 1024, lines: Int = 2000, tokens: Int = 30000) {
            self.bytes = max(4, min(bytes, 1024 * 1024))
            self.lines = max(1, min(lines, 10000))
            self.tokens = max(0, min(tokens, 100000))
        }
    }

    public enum Failure: Error { case notRegularFile, unreadable, invalidText }

    /// No file reads, decoding or tokenization run on the caller's actor. Cancellation reaches the worker.
    public static func load(_ url: URL, filename: String? = nil, limits: Limits = Limits()) async throws -> CodePreviewDocument {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try read(url, filename: filename ?? url.lastPathComponent, limits: limits)
        }
        return try await withTaskCancellationHandler {
            let document = try await worker.value
            try Task.checkCancellation()
            return document
        } onCancel: {
            worker.cancel()
        }
    }

    private static func read(_ url: URL, filename: String, limits: Limits) throws -> CodePreviewDocument {
        try Task.checkCancellation()
        guard url.isFileURL else { throw Failure.notRegularFile }
        // O_NONBLOCK avoids hanging on a FIFO before fstat can reject it. Symlinks to ordinary files work.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw Failure.unreadable }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw Failure.unreadable }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegularFile }
        var bytes = [UInt8](repeating: 0, count: limits.bytes + 1)
        var count = 0
        while count < bytes.count {
            try Task.checkCancellation()
            let amount = bytes.withUnsafeMutableBytes { storage in
                Darwin.read(descriptor, storage.baseAddress!.advanced(by: count), storage.count - count)
            }
            if amount == 0 { break }
            if amount < 0 {
                if errno == EINTR { continue }
                throw Failure.unreadable
            }
            count += amount
        }
        var truncated = count > limits.bytes
        let data = Data(bytes.prefix(min(count, limits.bytes)))
        var text = try decode(data, truncated: truncated)
        // Reject embedded NUL and binary control characters, while allowing ordinary text whitespace.
        guard !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 12, 13].contains($0.value) }) else {
            throw Failure.invalidText
        }
        var lineCount = 0
        var cut: String.Index?
        for index in text.indices where text[index].isNewline {
            lineCount += 1
            if lineCount == limits.lines {
                let next = text.index(after: index)
                if next < text.endIndex { cut = next }
                break
            }
        }
        if let cut { text = String(text[..<cut]); truncated = true }
        let displayedLines = text.isEmpty ? 0 : text.reduce(0) { $0 + ($1.isNewline ? 1 : 0) } + (text.last?.isNewline == true ? 0 : 1)
        try Task.checkCancellation()
        let language = SyntaxLanguage.detect(filename: filename, prefix: text) ?? .plain
        let tokens = try SyntaxTokenizer.tokenize(text, language: language, maximumTokens: limits.tokens)
        return CodePreviewDocument(text: text, language: language, tokens: tokens, displayedLines: displayedLines, truncated: truncated)
    }

    private static func decode(_ data: Data, truncated: Bool) throws -> String {
        var payload = data
        let encoding: String.Encoding
        let trimLimit: Int
        if payload.starts(with: [0xFF, 0xFE]) || payload.starts(with: [0xFE, 0xFF]) {
            encoding = payload.first == 0xFF ? .utf16LittleEndian : .utf16BigEndian
            payload.removeFirst(2)
            if truncated && payload.count % 2 != 0 { payload.removeLast() }
            trimLimit = 2
        } else {
            encoding = .utf8
            if payload.starts(with: [0xEF, 0xBB, 0xBF]) { payload.removeFirst(3) }
            trimLimit = 3
        }
        // A byte cap can split the final scalar; only a truncated input may drop that incomplete suffix.
        for trim in 0...(truncated ? min(trimLimit, payload.count) : 0) {
            if encoding != .utf8 && trim % 2 != 0 { continue }
            if encoding == .utf8 && trim > 0 && !incompleteUTF8(Array(payload.suffix(trim))) { continue }
            if encoding != .utf8 && trim == 2 {
                let tail = Array(payload.suffix(2))
                let unit = encoding == .utf16LittleEndian ? UInt16(tail[0]) | UInt16(tail[1]) << 8 : UInt16(tail[0]) << 8 | UInt16(tail[1])
                guard (0xD800...0xDBFF).contains(unit) else { continue }
            }
            if let text = String(data: payload.prefix(payload.count - trim), encoding: encoding) { return text }
        }
        throw Failure.invalidText
    }
    private static func incompleteUTF8(_ suffix: [UInt8]) -> Bool {
        guard let lead = suffix.first else { return false }
        let length = (0xC2...0xDF).contains(lead) ? 2 : (0xE0...0xEF).contains(lead) ? 3 : (0xF0...0xF4).contains(lead) ? 4 : 0
        guard suffix.count < length, suffix.dropFirst().allSatisfy({ (0x80...0xBF).contains($0) }) else { return false }
        if suffix.count > 1 {
            let second = suffix[1]
            if lead == 0xE0 && second < 0xA0 || lead == 0xED && second >= 0xA0 || lead == 0xF0 && second < 0x90 || lead == 0xF4 && second >= 0x90 {
                return false
            }
        }
        return true
    }

}
