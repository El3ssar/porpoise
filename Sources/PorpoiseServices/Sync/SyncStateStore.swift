import Foundation
import PorpoiseCore

public actor SyncStateStore {
    private let folder: URL
    private struct Record: Codable {
        var leftRoot: URL
        var rightRoot: URL
        var state: SyncState
    }
    public init(folder: URL? = nil) {
        self.folder =
            folder
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Porpoise/SyncState", isDirectory: true)
    }
    public func load(pairID: UUID, leftRoot: URL, rightRoot: URL) throws -> SyncState? {
        guard leftRoot.password == nil, rightRoot.password == nil else { throw SyncEngineError.invalidState }
        let file = folder.appendingPathComponent(pairID.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
        guard record.leftRoot == leftRoot, record.rightRoot == rightRoot, record.state.version == 1,
            record.state.left.complete, record.state.right.complete
        else { throw SyncEngineError.invalidState }
        return record.state
    }
    public func save(_ state: SyncState, pairID: UUID, leftRoot: URL, rightRoot: URL) throws {
        guard leftRoot.password == nil, rightRoot.password == nil, state.version == 1, state.left.complete, state.right.complete else {
            throw SyncEngineError.invalidState
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Record(leftRoot: leftRoot, rightRoot: rightRoot, state: state))
        try data.write(to: folder.appendingPathComponent(pairID.uuidString + ".json"), options: .atomic)
    }
}
