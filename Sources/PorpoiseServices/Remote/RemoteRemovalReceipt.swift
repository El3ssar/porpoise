import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// A provider captures its revision BEFORE the transfer reads the source. The returned operation must
/// atomically remove only that revision, or throw while preserving the current source. A fresh lookup
/// followed by ordinary delete does not satisfy this contract. Unsupported providers remain copy-only.
public protocol RemoteTransferConditionalRemoval: RemoteProvider {
    func captureTransferRemoval(_ source: URL) throws -> RemoteRemovalReceipt
}

public struct RemoteRemovalReceipt {
    private let removal: () throws -> Void
    public init(removeSource: @escaping () throws -> Void) { removal = removeSource }
    public func removeSource() throws { try removal() }
}

/// One receipt per attempted read; never synthesize deletion authority after publication.
struct MoveSourceRemoval {
    let local: LocalMoveRemovalReceipt?
    let remote: RemoteRemovalReceipt?

    init(_ source: URL) throws {
        local = source.isFileURL ? try LocalMoveRemovalReceipt(source: source, directoryOnly: FileItem.load(source)?.isDirectory == true) : nil
        remote = try (RemoteFS.provider(for: source) as? RemoteTransferConditionalRemoval)?.captureTransferRemoval(source)
    }

    func remove(afterVerifying target: URL) throws {
        if let local {
            do { try local.removeSource(afterVerifying: target) } catch {
                throw RemoteError.failed("Copy published; source retained. \(error.localizedDescription)")
            }
        } else if let remote {
            try remote.removeSource()
        } else {
            throw RemoteError.unsupported(
                "Copy published and verified; source retained because this provider cannot remove a specific source generation safely.")
        }
    }
}
