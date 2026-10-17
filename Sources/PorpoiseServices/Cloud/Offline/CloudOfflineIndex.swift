import CryptoKit
import Foundation

public enum CloudOfflineState: Equatable, Sendable {
    case cloudOnly, downloaded, kept, downloading(Double?), error(String)
}

public struct CloudOfflineEntry: Codable, Sendable {
    public var item: CloudRemoteItem
    public var path: String
    public var size: Int64
    public var lastUsed: Date
}

struct CloudOfflineIndex: Codable {
    var version = 1
    var entries: [String: CloudOfflineEntry] = [:]
    var items: [String: CloudRemoteItem] = [:]
    var pins: Set<String> = []
}

public struct CloudOfflineSnapshot: Sendable {
    public var entries: [String: CloudOfflineEntry]
    public var items: [String: CloudRemoteItem]
    public var pins: Set<String>
    public var progress: [String: Double]
    public var errors: [String: String]

    public func inheritedPin(_ id: String) -> String? {
        var seen: Set<String> = [id]
        var parents = items[id]?.parents ?? []
        while let parent = parents.popLast() {
            guard seen.insert(parent).inserted else { continue }
            if pins.contains(parent) { return parent }
            parents += items[parent]?.parents ?? []
        }
        return nil
    }
    public func isKept(_ id: String) -> Bool { pins.contains(id) || inheritedPin(id) != nil }
    public var usage: CloudOfflineUsage {
        entries.reduce(into: CloudOfflineUsage()) { usage, pair in
            if isKept(pair.key) { usage.kept += pair.value.size } else { usage.recent += pair.value.size }
        }
    }
}

extension CloudChecksum {
    /// Hash incrementally: full-file downloads must never require full-file resident memory.
    func verify(_ url: URL) throws -> Bool {
        if case .dropbox(let expected) = self { return try CloudContentHash.dropbox(url) == expected.lowercased() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var md5 = Insecure.MD5(); var sha = SHA256()
        while let bytes = try handle.read(upToCount: 1 << 20), !bytes.isEmpty {
            switch self {
            case .md5: md5.update(data: bytes)
            case .sha256: sha.update(data: bytes)
            case .dropbox, .quickXor: throw CloudContentError.unsupported
            }
        }
        switch self {
        case .md5(let expected): return md5.finalize().map { String(format: "%02x", $0) }.joined() == expected.lowercased()
        case .sha256(let expected): return sha.finalize().map { String(format: "%02x", $0) }.joined() == expected.lowercased()
        case .dropbox, .quickXor: throw CloudContentError.unsupported
        }
    }
}

func cloudObjectKey(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}
