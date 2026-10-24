import Foundation
import PorpoiseCore
import PorpoiseFileSystem

extension RemoteTransferJob {
    /// One durable conflict/publication/removal flow for every opaque-ID cloud provider.
    func transferCloud(_ source: URL, into folder: URL) throws -> URL? {
        if let target = completed[source] { finishProgress(source); return target }
        try control.checkpoint()
        let sourceProvider = RemoteFS.provider(for: source) as? CloudTransferProvider
        let targetProvider = RemoteFS.provider(for: folder) as? CloudTransferProvider
        let journal = try sourceProvider?.transferJournal(source) ?? targetProvider?.transferJournal(folder) ?? .shared
        if cloudOperations[source] == nil, cloudRecovered[journal.folder] == nil {
            cloudRecovered[journal.folder] = try journal.all().filter { $0.batchID == cloudBatchID }
        }
        let recovered =
            cloudOperations[source] == nil ? cloudRecovered[journal.folder]?.first { $0.source == source && $0.destinationFolder == folder } : nil
        let operation = cloudOperations[source] ?? recovered?.operationID ?? UUID(); cloudOperations[source] = operation
        let accounts = try [sourceProvider?.transferAccount(source), targetProvider?.transferAccount(folder)].compactMap { $0 }
        try journal.claim(operation, accounts: accounts, control: control)
        var record = CloudTransferRecord(operationID: operation, kind: kind == .move ? "move" : "copy", source: source, destinationFolder: folder)
        defer {
            if control.isCancelled && !control.isInterrupted {
                if let download = record.downloadOperationID { try? sourceProvider?.cancelTransferredOperation(download, at: source) }
                if let child = record.childOperationID { try? targetProvider?.cancelTransferredOperation(child, at: folder) }
            } else if record.phase == .done {
                if let download = record.downloadOperationID { try? sourceProvider?.cancelTransferredOperation(download, at: source) }
                let owned = journal.folder.appendingPathComponent("Sources").appendingPathComponent(operation.uuidString)
                if let staging = record.stagingURL, staging.deletingLastPathComponent() == owned,
                    JobJournal.Fingerprint(staging) == record.stagingFingerprint
                {
                    try? FileManager.default.removeItem(at: staging); _ = rmdir(owned.path)
                }
            }
            journal.release(operation)
        }
        if let saved = try journal.load(operation) { record = saved }
        guard record.source == source, record.destinationFolder == folder, record.kind == (kind == .move ? "move" : "copy") else {
            throw CloudTransferError.sourceChanged
        }
        if record.phase == .sourceRemovalPending {
            throw CloudEditError.denied("Source removal was interrupted. Review the original before retrying.")
        }
        if record.phase == .done, let target = record.targetURL {
            if record.skipped { skipConflict(source, target: target, identical: record.skippedIdentical); return nil }
            completed[source] = target; finishProgress(source); return target
        }
        if record.phase == .committed, let receipt = record.receipt {
            try verifyCloudReceipt(receipt); try finishCloudSource(source, provider: sourceProvider, record: &record, journal: journal)
            completed[source] = receipt.url; finishProgress(source); return receipt.url
        }
        guard let incoming = try item(source) else { throw CloudContentError.notFound }
        let snapshot = try sourceProvider?.transferSnapshot(source)
        if record.phase == .prepared {
            record.batchID = cloudBatchID; record.topLevel = !temporaryCopy && sources.contains(source)
            record.sourceAccount = try sourceProvider?.transferAccount(source);
            record.destinationAccount = try targetProvider?.transferAccount(folder)
            record.sourceSnapshot = snapshot; record.sourceRevision = snapshot?.item.revision
            record.sourceFingerprint = source.isFileURL ? JobJournal.Fingerprint(source) : nil
            try journal.save(record)
        }
        if source.isFileURL {
            guard record.sourceFingerprint == JobJournal.Fingerprint(source) else { throw CloudTransferError.sourceChanged }
        } else if let snapshot {
            guard record.sourceSnapshot.map({ $0.matches(snapshot) }) ?? (record.sourceRevision == snapshot.item.revision) else {
                throw CloudTransferError.sourceChanged
            }
        }
        let representation =
            try sourceProvider?.transferRepresentation(source, destinationAccount: record.destinationAccount)
            ?? CloudTransferRepresentation(name: incoming.name)
        if kind == .move, !representation.allowsMove {
            throw CloudEditError.denied("A native document export is a copy. The original stays in the cloud.")
        }
        var name = record.name ?? representation.name
        if targetProvider == nil { name = try RemoteFS.localName(name) }
        func mergeRecorded(_ target: URL) throws -> URL {
            record.targetURL = target; record.phase = .transferring; try journal.save(record)
            let result = try merge(source, into: target)
            record.phase = .done; try journal.save(record); return result
        }
        // A created folder is already owned by this batch; resume its children without creating it again.
        if incoming.isDirectory, !record.native, let target = record.targetURL { return try mergeRecorded(target) }
        if let child = record.childOperationID, let targetProvider,
            let receipt = try targetProvider.recoverTransfer(child, in: folder)
        {
            if incoming.isDirectory, !record.native { return try mergeRecorded(receipt.url) }
            try validateNativeCloudCopy(source: snapshot, receipt: receipt, native: record.native)
            record.receipt = receipt; record.targetURL = receipt.url; record.phase = .committed; try journal.save(record)
            try finishCloudSource(source, provider: sourceProvider, record: &record, journal: journal)
            completed[source] = receipt.url; finishProgress(source, copied: true); return receipt.url
        }
        var matches = try children(folder, fresh: true).filter { $0.name == name }
        guard matches.count <= 1 else { throw CloudEditError.denied("Several items have this name. Choose a different destination.") }
        var existing = matches.first, replace = false
        while let old = existing {
            if kind == .move, sourceProvider?.sameItem(old.url, source) == true || old.url == source {
                record.targetURL = source; record.phase = .done; try journal.save(record)
                completed[source] = source; finishProgress(source); return source
            }
            let suggestion = FileFormat.suggestedName(for: name, existing: Set(try children(folder).map(\.name)))
            switch try conflictDecision(source, incoming: incoming, existing: old, suggestion: suggestion) {
            case .cancel: control.cancel(); throw FileOperationError.cancelled
            case .skip(let identical):
                record.skipped = true; record.skippedIdentical = identical; record.targetURL = old.url; record.phase = .done; try journal.save(record)
                skipConflict(source, target: old.url, identical: identical); return nil
            case .rename(let chosen): try RemoteFS.checkName(chosen); name = chosen
            case .merge: return try mergeRecorded(old.url)
            case .replace: replace = true
            case .compareContents: preconditionFailure("Content comparison must be resolved before placement")
            }
            if replace { break }
            matches = try children(folder, fresh: true).filter { $0.name == name }
            guard matches.count <= 1 else { throw CloudEditError.notSupported }; existing = matches.first
        }
        if replace, let old = existing { try Self.checkReplaceable(incoming, old) }
        let targetRevision = try existing.flatMap { try targetProvider?.transferSnapshot($0.url).item.revision }
        record.name = name; record.phase = .transferring
        if record.childOperationID == nil { record.childOperationID = UUID() }
        if record.downloadOperationID == nil { record.downloadOperationID = UUID() }
        try journal.save(record)
        let child = record.childOperationID!, download = record.downloadOperationID!
        progressLock.withLock {
            progress.currentName = incoming.name; activeLimit = totals[source]?.bytes ?? incoming.size; activeLegs = legCount(source); activeBytes = 0
        }
        var receipt: CloudTransferReceipt?
        if !replace, let targetProvider, record.sourceAccount != nil, record.sourceAccount == record.destinationAccount,
            control.policy.exclusions.isEmpty || !incoming.isDirectory,
            !incoming.isDirectory || targetProvider.supportsNativeTransferFolders
        {
            record.native = true; try journal.save(record)
            receipt = try targetProvider.nativeTransfer(source, into: folder, named: name, move: kind == .move, operationID: child)
            if receipt == nil { record.native = false; try journal.save(record) }
        }
        if let receipt {
            try validateNativeCloudCopy(source: snapshot, receipt: receipt, native: true)
            record.receipt = receipt; record.targetURL = receipt.url; record.phase = .committed; try journal.save(record)
            try finishCloudSource(source, provider: sourceProvider, record: &record, journal: journal)
        } else if incoming.isDirectory {
            guard !replace else { throw CloudEditError.notSupported }
            let target: URL
            if let targetProvider {
                target = try targetProvider.createTransferFolder(named: name, in: folder, operationID: child).url
            } else {
                target = folder.appendingPathComponent(name)
                try CopyNamePreflight.validateDestination(target, source: source)
                if let provider = RemoteFS.provider(for: folder) {
                    try provider.makeFolder(target)
                } else {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                }
            }
            listings[folder] = nil; return try mergeRecorded(target)
        } else if let targetProvider {
            guard !incoming.isSymlink else { throw CloudEditError.notSupported }
            // The upload journal fingerprints this path; keep it stable across retries and process death.
            let scratch = journal.folder.appendingPathComponent("Sources").appendingPathComponent(operation.uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let local: URL
            if source.isFileURL {
                local = source
            } else if let kept = try FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil).first {
                // A retry may use only our fingerprinted bytes, or a download verified before
                // the parent checkpoint reached disk. Never adopt an arbitrary private file.
                if let expected = record.stagingFingerprint {
                    guard record.stagingURL == kept, JobJournal.Fingerprint(kept) == expected else { throw CloudTransferError.sourceChanged }
                } else {
                    guard let checksum = snapshot?.item.checksum, try checksum.verify(kept) else { throw CloudTransferError.sourceChanged }
                }
                local = kept
            } else if let sourceProvider {
                local = try TransferRetry.run(control: control, notice: onNotice) {
                    try sourceProvider.downloadTransfer(source, into: scratch, operationID: download)
                }
            } else {
                local = try TransferRetry.run(control: control, notice: onNotice) {
                    try RemoteFS.provider(for: source)!.download(source, into: scratch)
                }
            }
            if !source.isFileURL {
                record.stagingURL = local; record.stagingFingerprint = JobJournal.Fingerprint(local); try journal.save(record)
            }
            let result = try targetProvider.uploadTransfer(
                local, in: folder, named: name, replacing: replace ? existing?.url : nil,
                expectedRevision: targetRevision, operationID: child)
            record.receipt = result; record.targetURL = result.url; record.phase = .committed; try journal.save(record)
            try finishCloudSource(source, provider: sourceProvider, record: &record, journal: journal)
        } else {
            let target = folder.appendingPathComponent(name)
            try stagedFile(
                source, to: target, replacing: replace, modified: incoming.modificationDate,
                beforeSourceRemoval: {
                    let receipt: CloudTransferReceipt
                    if target.isFileURL {
                        receipt = .init(url: target, fingerprint: JobJournal.Fingerprint(target))
                    } else {
                        let digest = try self.digest(target)
                        guard digest == (try self.digest(source)) else { throw CloudTransferError.sourceChanged }
                        receipt = .init(url: target, digest: digest)
                    }
                    record.receipt = receipt; record.targetURL = target; record.phase = .committed; try journal.save(record)
                    try self.finishCloudSource(source, provider: sourceProvider, record: &record, journal: journal)
                }, sourceDownloadOperationID: download, sourceRemovalHandled: true)
        }
        guard let target = record.targetURL else { throw CloudContentError.notFound }
        if record.phase != .done { record.phase = .done; try journal.save(record) }
        completed[source] = target; listings[folder] = nil
        if replace { progressLock.withLock { progress.replacedItems += 1 } }
        finishProgress(source, copied: true); return target
    }
    private func validateNativeCloudCopy(source: CloudTransferSnapshot?, receipt: CloudTransferReceipt, native: Bool) throws {
        guard native, !receipt.sourceRemoved, let source, let target = receipt.snapshot else { return }
        if source.item.isFolder { return }
        if let nativeType = source.nativeType {
            guard nativeType == target.nativeType else { throw CloudTransferError.sourceChanged }
        } else {
            guard let checksum = source.item.checksum, checksum == target.item.checksum, source.item.size == target.item.size else {
                throw CloudTransferError.sourceChanged
            }
        }
    }
    private func verifyCloudReceipt(_ receipt: CloudTransferReceipt) throws {
        if let provider = RemoteFS.provider(for: receipt.url) as? CloudTransferProvider {
            try provider.verifyTransfer(receipt)
        } else if receipt.url.isFileURL {
            guard let expected = receipt.fingerprint, JobJournal.Fingerprint(receipt.url) == expected else { throw CloudTransferError.sourceChanged }
        } else {
            guard let expected = receipt.digest, try digest(receipt.url) == expected else { throw CloudTransferError.sourceChanged }
        }
    }
    private func finishCloudSource(_ source: URL, provider: CloudTransferProvider?, record: inout CloudTransferRecord, journal: CloudTransferJournal)
        throws
    {
        if kind == .move, record.receipt?.sourceRemoved != true {
            try verifyCloudReceipt(record.receipt!)
            if source.isFileURL {
                guard record.sourceFingerprint == JobJournal.Fingerprint(source) else { throw CloudTransferError.sourceChanged }
            } else if provider == nil {
                guard let checksum = record.receipt?.snapshot?.item.checksum else { throw CloudTransferError.sourceChanged }
                let scratch = try Self.temporaryFolder(); defer { try? FileManager.default.removeItem(at: scratch) }
                guard let local = try RemoteFS.provider(for: source)?.download(source, into: scratch), try checksum.verify(local) else {
                    throw CloudTransferError.sourceChanged
                }
            }
            record.phase = .sourceRemovalPending; try journal.save(record)
            if let provider {
                try provider.removeTransferredSource(source, snapshot: record.sourceSnapshot, revision: record.sourceRevision)
            } else {
                try removeOriginal(source)
            }
        }
        record.phase = .done; try journal.save(record)
        if kind == .move, let target = record.receipt?.url { movedItems[source] = target }
    }

    static func checkReplaceable(_ incoming: FileItem, _ existing: FileItem) throws {
        guard incoming.isDirectory || existing.isDirectory else { return }
        throw RemoteError.unsupported(
            "“\(existing.name)” can’t be replaced by “\(incoming.name)”: one is a folder or a link to one. Keep Both instead.")
    }
}
