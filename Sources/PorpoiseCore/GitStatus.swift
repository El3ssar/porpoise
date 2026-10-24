import Foundation

/// Git porcelain v2 is NUL-delimited: paths are never quoted or split on whitespace.
public enum GitFileStatus: String, Sendable, CaseIterable {
    case modified, added, untracked, conflicted, renamed, deleted, ignored, changedFolder

    public var label: String {
        switch self {
        case .modified: "Git: modified"
        case .added: "Git: added"
        case .untracked: "Git: untracked"
        case .conflicted: "Git: conflicted"
        case .renamed: "Git: renamed"
        case .deleted: "Git: deleted"
        case .ignored: "Git: ignored"
        case .changedFolder: "Git: changes inside"
        }
    }
    public var symbol: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .untracked: "?"
        case .conflicted: "!"
        case .renamed: "R"
        case .deleted: "D"
        case .ignored: ""
        case .changedFolder: "•"
        }
    }
}

public struct GitStatusSnapshot: Sendable, Equatable {
    public var branch: String?
    public var revision: String?
    public var ahead = 0
    public var behind = 0
    public var files: [String: GitFileStatus] = [:]
    public var originalPaths: [String: String] = [:]
    public var changedFolders: Set<String> = []
    public init() {}
    public var branchText: String {
        let name = branch == "(detached)" ? "Detached \(revision?.prefix(8) ?? "HEAD")" : branch ?? "HEAD"
        return "⎇ \(name)" + (ahead > 0 ? " ↑\(ahead)" : "") + (behind > 0 ? " ↓\(behind)" : "")
    }
    public func status(for path: String, directory: Bool) -> GitFileStatus? {
        if let status = files[path] { return directory && status != .ignored ? .changedFolder : status }
        if directory && changedFolders.contains(path) { return .changedFolder }
        // --ignored=matching collapses whole ignored directories. Their descendants are dimmed too.
        var parent = path
        while let slash = parent.lastIndex(of: "/") {
            parent = String(parent[..<slash])
            if files[parent] == .ignored { return .ignored }
            if files[parent] == .untracked { return directory ? .changedFolder : .untracked }
        }
        return nil
    }
}

public enum GitStatusParser {
    public enum Invalid: Error { case record }
    public static func parse(_ data: Data) throws -> GitStatusSnapshot {
        guard data.isEmpty || data.last == 0 else { throw Invalid.record }
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
        var result = GitStatusSnapshot(), index = 0
        while index < records.count {
            let bytes = records[index]; index += 1
            if bytes.isEmpty { continue }
            guard let record = String(data: Data(bytes), encoding: .utf8) else { throw Invalid.record }
            if record.hasPrefix("# branch.head ") { result.branch = String(record.dropFirst(14)); continue }
            if record.hasPrefix("# branch.oid ") { result.revision = String(record.dropFirst(13)); continue }
            if record.hasPrefix("# branch.ab ") {
                let ab = record.dropFirst(12).split(separator: " ")
                guard ab.count == 2, ab[0].first == "+", ab[1].first == "-",
                    let ahead = Int(ab[0].dropFirst()), let behind = Int(ab[1].dropFirst()), ahead >= 0, behind >= 0
                else { throw Invalid.record }
                result.ahead = ahead; result.behind = behind; continue
            }
            if record.hasPrefix("# ") { continue }
            let fields: [Substring], status: GitFileStatus
            switch record.first {
            case "?", "!":
                fields = record.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                status = record.first == "?" ? .untracked : .ignored
            case "1", "2", "u":
                let count = record.first == "1" ? 8 : record.first == "2" ? 9 : 10
                fields = record.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false)
                guard fields.count == count + 1, fields[1].count == 2 else { throw Invalid.record }
                let xy = fields[1]
                if record.first == "u" {
                    status = .conflicted
                } else if xy.contains("R") || xy.contains("C") {
                    status = .renamed
                } else if xy.contains("A") {
                    status = .added
                } else if xy.contains("D") {
                    status = .deleted
                } else {
                    status = .modified
                }
            default: throw Invalid.record
            }
            guard fields.count >= 2 else { throw Invalid.record }
            var path = String(fields.last!)
            if path.hasSuffix("/") { path.removeLast() }
            guard validPath(path) else { throw Invalid.record }
            result.files[path] = status
            if record.first == "2" {
                guard index < records.count, let original = String(data: Data(records[index]), encoding: .utf8), validPath(original)
                else { throw Invalid.record }
                result.originalPaths[path] = original; index += 1
                addParents(original, to: &result.changedFolders)
            }
            if status != .ignored { addParents(path, to: &result.changedFolders) }
        }
        return result
    }
    public static func validPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.utf8.contains(0)
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
    }
    private static func addParents(_ path: String, to folders: inout Set<String>) {
        var parent = path
        while let slash = parent.lastIndex(of: "/") {
            parent = String(parent[..<slash]); folders.insert(parent)
        }
    }
}

/// Refresh admission is independent of IO: adaptive spacing, bounded retries and explicit reload recovery.
public struct GitRefreshState: Sendable {
    public private(set) var failures = 0
    private var lastStart: TimeInterval = -.infinity
    private var duration: TimeInterval = 0
    private var retryAfter: TimeInterval = 0
    public init() {}
    public var isPaused: Bool { failures >= 3 }
    public func delay(at now: TimeInterval) -> TimeInterval? {
        guard !isPaused else { return nil }
        return max(0.4, lastStart + max(0.4, duration * 4) - now, retryAfter - now)
    }
    public mutating func finished(success: Bool, start: TimeInterval, end: TimeInterval) {
        lastStart = start; duration = max(0, end - start)
        failures = success ? 0 : failures + 1
        retryAfter = success ? 0 : end + 10
    }
    public mutating func resume() { failures = 0; retryAfter = 0 }
}
