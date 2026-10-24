import Darwin
import Foundation
import PorpoiseCore

/// Administrator retries never replace a target. The existing helper publishes `mv -n` with RENAME_EXCL;
/// raw shell cp/mv cannot supply that contract, so this path fails closed without the helper.
/// A failed copy publication retains its staged bytes and reports their recovery path instead of deleting by name.
final class AdministratorTransferBatch: @unchecked Sendable {
    typealias Elevate = ([[String]], Bool, [String]) -> FileOperationsController.ElevatedOutcome
    struct Completion {
        var targets: [URL] = []
        var moves: [(from: URL, to: URL)] = []
        var errors: [String] = []
    }
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            device = info.st_dev; inode = info.st_ino
        }
    }
    let kind: FileOperationKind
    private let commands: [[String]]
    private let elevate: Elevate
    private let lock = NSLock()
    private var finished = Completion()
    var completion: Completion { lock.withLock { finished } }

    init(kind: FileOperationKind, commands: [[String]], elevate: @escaping Elevate) {
        self.kind = kind; self.commands = commands; self.elevate = elevate
    }

    static func occupied(_ target: URL) -> String {
        "“\(target.lastPathComponent)” already exists; the existing item was left unchanged. Choose another name."
    }

    private static func absent(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return false }
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return true
    }

    /// Worker-only; the main-thread completion reads only receipts that were verified after publication.
    func run(viaHelper: Bool) -> FileOperationsController.ElevatedOutcome {
        var result = Completion(), cancelled = false
        defer { lock.withLock { finished = result } }
        guard viaHelper else {
            result.errors = ["This administrator copy or move needs Porpoise’s helper to publish safely. No items were changed."]
            return .failed(result.errors[0])
        }
        for command in commands {
            guard command.count >= 4, (kind == .copy && command.first == "/bin/cp") || (kind == .move && command.first == "/bin/mv") else {
                result.errors.append("The administrator transfer could not be verified."); continue
            }
            let source = URL(fileURLWithPath: command[command.count - 2]), target = URL(fileURLWithPath: command[command.count - 1])
            var staged: URL?
            var publicationSource: URL?
            var publicationIdentity: Identity?
            do {
                // Re-check on the worker immediately before the first request, not just while building the plan.
                guard try Self.absent(target) else { result.errors.append(Self.occupied(target)); continue }
                let published: URL
                let identity: Identity
                if kind == .copy {
                    let copy = target.deletingLastPathComponent().appendingPathComponent(".porpoise-copy-" + UUID().uuidString)
                    guard try Self.absent(copy) else { throw CocoaError(.fileWriteFileExists) }
                    staged = copy
                    switch elevate([["/bin/cp", "-pR", "--", source.path, copy.path]], true, []) {
                    case .done: break
                    case .cancelled: cancelled = true; throw CancellationError()
                    case .failed(let message): throw TransferFailure(message)
                    }
                    published = copy; identity = try Identity(copy)
                } else {
                    published = source; identity = try Identity(source)
                }
                publicationSource = published; publicationIdentity = identity
                // A copy may have taken a long time. Never let the final request replace what arrived meanwhile.
                guard try Self.absent(target) else { throw TransferFailure(Self.occupied(target)) }
                switch elevate([["/bin/mv", "-n", "--", published.path, target.path]], true, []) {
                case .done: break
                case .cancelled: cancelled = true; throw CancellationError()
                case .failed(let message): throw TransferFailure(message)
                }
                // `mv -n` can succeed without moving. Only the same inode at target, absent at source, is a receipt.
                guard try Self.absent(published), try Identity(target) == identity else {
                    throw TransferFailure("The transfer could not be confirmed; no completed item was recorded.")
                }
                result.targets.append(target)
                if kind == .move { result.moves.append((from: source, to: target)) }
            } catch {
                var message = error is CancellationError ? "The administrator transfer was cancelled." : error.localizedDescription
                if let publicationSource, let publicationIdentity, (try? Identity(publicationSource)) == publicationIdentity,
                    (try? Self.absent(target)) == false
                {
                    message = Self.occupied(target)
                }
                if let staged, (try? Self.absent(staged)) != true {
                    message += " A copy may be kept for recovery at: \(staged.path)."
                } else if error is CancellationError {
                    break
                }
                result.errors.append(message)
            }
            if cancelled { break }
        }
        if !result.errors.isEmpty { return .failed(result.errors.joined(separator: "\n")) }
        return cancelled ? .cancelled : .done
    }

    private struct TransferFailure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
