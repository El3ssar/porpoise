import Foundation
import PorpoiseCore

/// Publication through opaque IDs. A receipt is accepted only after the provider verifies its destination.
public protocol CloudTransferProvider: CloudFileProvider {
    func transferAccount(_ url: URL) throws -> String
    func transferSnapshot(_ url: URL) throws -> CloudTransferSnapshot
    func transferRepresentation(_ source: URL, destinationAccount: String?) throws -> CloudTransferRepresentation
    func transferJournal(_ url: URL) throws -> CloudTransferJournal
    var recoveryTransferJournals: [CloudTransferJournal] { get }
    var supportsNativeTransferFolders: Bool { get }
    func smallTransferItem(_ source: URL) -> FileItem?
    func createTransferFolder(named name: String, in folder: URL, operationID: UUID) throws -> CloudTransferReceipt
    func uploadTransfer(_ local: URL, in folder: URL, named name: String, replacing: URL?, expectedRevision: String?, operationID: UUID) throws
        -> CloudTransferReceipt
    func nativeTransfer(_ source: URL, into folder: URL, named name: String, move: Bool, operationID: UUID) throws -> CloudTransferReceipt?
    func recoverTransfer(_ operation: UUID, in folder: URL) throws -> CloudTransferReceipt?
    func verifyTransfer(_ receipt: CloudTransferReceipt) throws
    func downloadTransfer(_ source: URL, into folder: URL, operationID: UUID) throws -> URL
    func removeTransferredSource(_ source: URL, snapshot: CloudTransferSnapshot?, revision: String?) throws
    func cancelTransferredOperation(_ operation: UUID, at url: URL) throws
}
extension CloudTransferProvider {
    public func transferRevision(_ source: URL) -> String? { try? transferSnapshot(source).item.revision }
    func transferChecksum(_ source: URL) throws -> CloudChecksum? { try transferSnapshot(source).item.checksum }
}

extension CloudChecksum {
    var algorithm: String {
        switch self {
        case .md5: return "md5"
        case .sha256: return "sha256"
        case .dropbox: return "dropbox"
        case .quickXor: return "quickXor"
        case .sha1: return "sha1"
        }
    }
}
