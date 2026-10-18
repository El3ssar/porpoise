import Foundation
import PorpoiseCore

/// What file operations did: one line per job, searchable and exportable for troubleshooting. Paths only, never
/// passwords or tokens (remote locations are written without them).
public struct HistoryEntry: Codable, Equatable, Sendable {
    public var date: Date
    public var operation: String
    public var items: Int
    /// Up to five of the items.
    public var sources: [String]
    public var destination: String?
    public var bytes: Int64
    public var seconds: Double
    /// Completed, Completed with errors, Cancelled, Interrupted, Failed.
    public var outcome: String
    public var errors: [String]
    public var verification: String?

    public init(
        date: Date, operation: String, items: Int, sources: [String], destination: String?, bytes: Int64, seconds: Double,
        outcome: String, errors: [String], verification: String? = nil
    ) {
        self.date = date
        self.operation = operation
        self.items = items
        self.sources = sources
        self.destination = destination
        self.bytes = bytes
        self.seconds = seconds
        self.outcome = outcome
        self.errors = errors
        self.verification = verification
    }

    func matches(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return true }
        let haystack = ([operation, outcome, destination ?? "", verification ?? ""] + sources + errors).joined(separator: "\n")
        return t.split(separator: " ").allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

public final class OperationHistory: @unchecked Sendable {
    public static let shared = OperationHistory(file: OperationHistory.defaultFile)
    public static let changed = Notification.Name("PorpoiseOperationHistoryChanged")
    /// The newest entries kept.
    static let limit = 5000

    public let file: URL
    /// Every read and write, in order: a job's entry is written here, not on the main thread that ends it.
    private let queue = DispatchQueue(label: "app.porpoise.history", qos: .utility)
    private var cache: [HistoryEntry]?

    public init(file: URL) { self.file = file }

    static var defaultFile: URL {
        Settings.supportFolder.appendingPathComponent("history.jsonl")
    }

    /// A location as it may be written down: local paths as they are, remote ones without user, password,
    /// query or fragment.
    public static func describe(_ url: URL) -> String {
        guard !url.isFileURL else { return url.path }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.user = nil
        c?.password = nil
        c?.query = nil
        c?.fragment = nil
        return c?.string ?? (url.scheme ?? "remote") + "://"
    }

    public func append(_ entry: HistoryEntry) {
        queue.async { [self] in
            var all = load()
            all.append(entry)
            if all.count > Self.limit + Self.limit / 5 {
                all.removeFirst(all.count - Self.limit)
                write(all)
            } else {
                try? FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if let line = try? Self.encoder.encode(entry) {
                    if let h = try? FileHandle(forWritingTo: file) {
                        h.seekToEndOfFile()
                        h.write(line + Data([10]))
                        try? h.close()
                    } else {
                        try? (line + Data([10])).write(to: file, options: .atomic)
                    }
                }
            }
            cache = all
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) }
        }
    }

    /// Waits until every entry asked for is written (before quitting).
    public func flush() {
        queue.sync {}
    }

    /// Newest first, those matching every word of `search` (any field).
    public func entries(matching search: String = "") -> [HistoryEntry] {
        queue.sync { load() }.reversed().filter { $0.matches(search) }
    }

    public func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: file)
            cache = []
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) }
    }

    /// CSV (RFC 4180) with a header row, for a spreadsheet or a bug report.
    public static func csv(_ entries: [HistoryEntry]) -> String {
        func field(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var out = "Date,Operation,Items,Sources,Destination,Bytes,Seconds,Outcome,Errors,Verification\r\n"
        for e in entries {
            let row = [
                FileFormat.iso8601(e.date), e.operation, String(e.items), e.sources.joined(separator: "\n"), e.destination ?? "", String(e.bytes),
                String(format: "%.1f", e.seconds), e.outcome, e.errors.joined(separator: "\n"), e.verification ?? "",
            ]
            out += row.map(field).joined(separator: ",") + "\r\n"
        }
        return out
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// On the queue.
    private func load() -> [HistoryEntry] {
        if let cache { return cache }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let all = text.split(separator: "\n").compactMap { try? dec.decode(HistoryEntry.self, from: Data($0.utf8)) }
        cache = all
        return all
    }

    /// On the queue.
    private func write(_ all: [HistoryEntry]) {
        let data = all.compactMap { try? Self.encoder.encode($0) }.reduce(into: Data()) { $0 += $1 + Data([10]) }
        try? data.write(to: file, options: .atomic)
    }
}
