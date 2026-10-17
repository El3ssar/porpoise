import Foundation
import PorpoiseCore

extension RemoteTransferJob {
    /// Drive names are presentation; target and source identity always come from opaque IDs.
    func transferDrive(_ source: URL, into folder: URL) throws -> URL? {
        if let target = completed[source] { finishProgress(source); return target }
        guard let incoming = try item(source) else { throw DriveError.notFound }
        let sourceProvider = RemoteFS.provider(for: source) as? DriveProvider
        let targetProvider = RemoteFS.provider(for: folder) as? DriveProvider
        let journal = sourceProvider?.client?.mutationJournal ?? targetProvider?.client?.mutationJournal ?? .shared
        let recovered =
            cloudOperations[source] == nil
            ? try journal.all().first { $0.batchID == cloudBatchID && $0.localSource == source && $0.destinationFolder == folder }
            : nil
        let operationID = cloudOperations[source] ?? recovered?.operationID ?? UUID()
        cloudOperations[source] = operationID
        let accountID = sourceProvider?.accountID ?? targetProvider!.accountID
        let metadata = sourceProvider?.metadata(for: source)
        var record =
            try journal.load(operationID)
            ?? DriveMutationRecord(
                operationID: operationID, accountID: accountID, kind: kind == .move ? "transferMove" : "transferCopy", sourceID: metadata?.id)
        if record.phase == .sourceRemovalPending { throw DriveMutationError.uncertain }
        if record.phase == .done, let target = record.destinationURL {
            completed[source] = target; finishProgress(source); return target
        }
        if record.phase == .committed, let target = record.destinationURL {
            if target.isFileURL {
                guard JobJournal.Fingerprint(target) == record.destinationFingerprint else { throw DriveMutationError.sourceChanged }
            } else if let provider = RemoteFS.provider(for: target) as? DriveProvider, let client = provider.client, let expected = record.result {
                let fresh = try DriveProvider.wait { try await client.file(expected.id) }
                guard fresh.version == expected.version, fresh.size == expected.size, fresh.md5Checksum == expected.md5Checksum else {
                    throw DriveMutationError.sourceChanged
                }
            } else if let expected = record.destinationDigest {
                guard try digest(target) == expected else { throw DriveMutationError.sourceChanged }
            } else {
                throw DriveMutationError.uncertain
            }
            try finishDriveSource(source, metadata: metadata, record: &record, journal: journal)
            completed[source] = target; finishProgress(source); return target
        }
        if record.phase == .prepared {
            record.batchID = cloudBatchID
            record.destinationFolder = folder; record.topLevel = sources.contains(source)
            record.localSource = source
            record.fingerprint = source.isFileURL ? JobJournal.Fingerprint(source) : nil
            record.revision = metadata?.version
            try journal.save(record)
        }
        guard record.revision == metadata?.version,
            !source.isFileURL || record.fingerprint == JobJournal.Fingerprint(source)
        else { throw DriveMutationError.sourceChanged }
        // A native document export is a representation, never proof permitting source removal.
        let exportsNative = incoming.isWebDocument && targetProvider?.accountID != sourceProvider?.accountID
        if kind == .move, exportsNative { throw DriveError.unsupportedExport }
        var name = incoming.name
        if exportsNative,
            let file = metadata,
            let format = (DriveExportPreset(rawValue: Settings.store.string(forKey: "googleDriveExportPreset") ?? "") ?? .office).format(
                for: file.mimeType)
        {
            name += "." + format.fileExtension
        }
        // Anywhere but Drive, the name becomes a path component: never more than one.
        if targetProvider == nil { name = try RemoteFS.localName(name) }
        func mergeRecorded(_ target: URL) throws -> URL {
            record.destinationURL = target; record.phase = .transferring; try journal.save(record)
            let merged = try merge(source, into: target)
            record.phase = .done; try journal.save(record)
            return merged
        }
        let matches = try children(folder, fresh: true).filter { $0.name == name }
        guard matches.count <= 1 else { throw DriveMutationError.conflict }
        var existing = matches.first
        if existing?.url == source, kind == .move { completed[source] = source; finishProgress(source); return source }
        var replacing = false
        while let old = existing {
            let bothFolders = Self.isFolderPair(incoming, old)
            let suggestion = FileFormat.suggestedName(for: name, existing: Set(try children(folder).map(\.name)))
            let answer: ConflictAnswer
            // "Replace" chosen for folders asks again for anything but two folders, as local copies do.
            if let choice = sticky ?? rule.resolution, choice != .writeInto || bothFolders {
                answer = .init(choice)
            } else {
                answer = resolve(.init(source: incoming, destination: old, suggestedName: suggestion, comparisonOptions: options))
            }
            if let method = answer.comparisonMethod { options.method = method }
            if answer.applyToAll { sticky = answer.resolution }
            switch answer.resolution {
            case .cancel: control.cancel(); throw FileOperationError.cancelled
            case .skip: completed[source] = old.url; finishProgress(source); return nil
            case .keepBoth: name = suggestion; existing = nil
            case .rename(let chosen):
                try RemoteFS.checkName(chosen); name = chosen
                let matches = try children(folder).filter { $0.name == name }
                guard matches.count <= 1 else { throw DriveMutationError.conflict }
                existing = matches.first
            case .writeInto:
                guard bothFolders else { throw DriveMutationError.conflict }
                return try mergeRecorded(old.url)
            case .overwriteIfDifferent:
                if bothFolders { return try mergeRecorded(old.url) }
                if try identical(source, incoming, old.url, old) {
                    progressLock.withLock { progress.skippedIdenticalItems += 1 }
                    completed[source] = old.url; finishProgress(source); return nil
                }
                replacing = true
            case .overwriteIfOlder, .overwriteIfLarger:
                if bothFolders { return try mergeRecorded(old.url) }
                guard answer.resolution.shouldReplace(source: incoming, destination: old, options: options) else {
                    completed[source] = old.url; finishProgress(source); return nil
                }
                replacing = true
            case .overwrite:
                if bothFolders { return try mergeRecorded(old.url) }
                replacing = true
            }
            if replacing { break }
        }
        if replacing, let old = existing { try Self.checkReplaceable(incoming, old) }
        if replacing, let old = existing, (RemoteFS.provider(for: old.url) as? DriveProvider)?.metadata(for: old.url)?.isGoogleDocument == true {
            throw RemoteError.unsupported("A Google document cannot be replaced with uploaded bytes. Export it or choose Keep Both.")
        }
        let finalName = name
        if incoming.isDirectory {
            let target: URL
            if let existingTarget = record.destinationURL {
                target = existingTarget
            } else if let targetProvider, let client = targetProvider.client {
                if record.childOperationID == nil { record.childOperationID = UUID(); try journal.save(record) }
                let child = record.childOperationID!, parent = try targetProvider.parentID(folder)
                target = try DriveProvider.wait {
                    try await client.createFolder(name: finalName, parentID: parent, operationID: child).childLocation(
                        in: DriveLocation(url: folder)!
                    ).url
                }
            } else {
                target = folder.appendingPathComponent(name)
                if let provider = RemoteFS.provider(for: folder) {
                    try provider.makeFolder(target)
                } else {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                }
            }
            listings[folder] = nil
            return try mergeRecorded(target)
        }
        progressLock.withLock {
            progress.currentName = incoming.name; activeLimit = totals[source]?.bytes ?? incoming.size
            activeLegs = legCount(source); activeBytes = 0
        }
        let target: URL
        if let provider = targetProvider, let client = provider.client {
            let parent = try provider.parentID(folder)
            // Derive a distinct stable operation UUID for the remote commit, retained in the transfer record.
            if record.childOperationID == nil { record.childOperationID = UUID(); try journal.save(record) }
            let child = record.childOperationID!
            let result: DriveFile
            var serverMoved = false
            if replacing, let old = existing {
                guard let oldFile = provider.metadata(for: old.url) else { throw DriveMutationError.conflict }
                let scratch = journal.folder.appendingPathComponent("Sources").appendingPathComponent(operationID.uuidString)
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let local: URL
                if source.isFileURL {
                    local = source
                } else if let kept = try FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil).first {
                    local = kept
                } else {
                    local = try RemoteFS.provider(for: source)!.download(source, into: scratch)
                }
                let context = provider.transferContext()
                result = try DriveProvider.wait {
                    try await client.upload(
                        local, parentID: parent, name: finalName, operationID: child, context: context,
                        replacingID: oldFile.id, expectedVersion: oldFile.version)
                }
            } else if let sourceProvider, sourceProvider.accountID == provider.accountID, let metadata {
                let destinationParent = try DriveProvider.wait { try await client.file(parent) }
                if kind == .move && metadata.driveId == destinationParent.driveId {
                    result = try DriveProvider.wait { try await client.move(metadata.id, to: parent, operationID: child, name: finalName) }
                    serverMoved = true
                } else {
                    if kind == .move, metadata.capabilities?.canMoveItemOutOfDrive != true { throw DriveError.permissionDenied }
                    result = try DriveProvider.wait { try await client.copy(metadata.id, to: parent, name: finalName, operationID: child) }
                }
            } else {
                let scratch = journal.folder.appendingPathComponent("Sources").appendingPathComponent(operationID.uuidString)
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let local: URL
                if source.isFileURL {
                    local = source
                } else if let kept = try FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil).first {
                    local = kept
                } else {
                    local = try RemoteFS.provider(for: source)!.download(source, into: scratch)
                }
                let context = provider.transferContext()
                result = try DriveProvider.wait {
                    try await client.upload(local, parentID: parent, name: finalName, operationID: child, context: context)
                }
            }
            let verified = try DriveProvider.wait { try await client.file(result.id) }
            guard verified.version == result.version, verified.size == result.size, verified.md5Checksum == result.md5Checksum else {
                throw DriveMutationError.conflict
            }
            if let metadata, !serverMoved, !replacing, !exportsNative {
                guard
                    metadata.isGoogleDocument
                        ? metadata.mimeType == result.mimeType
                        : (metadata.md5Checksum != nil && metadata.md5Checksum == result.md5Checksum && metadata.size == result.size)
                else {
                    throw DriveMutationError.sourceChanged
                }
            }
            target = result.childLocation(in: DriveLocation(url: folder)!).url
            record.result = result; record.destinationURL = target; record.phase = .committed; try journal.save(record)
            if kind == .move, !serverMoved {
                try finishDriveSource(source, metadata: metadata, record: &record, journal: journal)
            }
        } else {
            target = folder.appendingPathComponent(name)
            if record.downloadOperationID == nil { record.downloadOperationID = UUID(); try journal.save(record) }
            let downloadID = record.downloadOperationID!
            try stagedFile(
                source, to: target, replacing: replacing, modified: incoming.modificationDate,
                beforeSourceRemoval: {
                    record.destinationURL = target; record.destinationFingerprint = JobJournal.Fingerprint(target)
                    if !target.isFileURL {
                        record.destinationDigest = try self.digest(target)
                        guard record.destinationDigest == (try self.digest(source)) else { throw DriveMutationError.sourceChanged }
                    }
                    record.phase = .committed; try journal.save(record)
                    if self.kind == .move {
                        guard
                            try sourceProvider?.client.map({ client in
                                try DriveProvider.wait { try await client.file(metadata!.id).version }
                            }) == record.revision
                        else { throw DriveMutationError.sourceChanged }
                        record.phase = .sourceRemovalPending; try journal.save(record)
                    }
                }, sourceDownloadOperationID: downloadID)
        }
        record.destinationURL = target; record.phase = .done; try journal.save(record)
        completed[source] = target; finishProgress(source, copied: true); listings[folder] = nil
        return target
    }

    private func finishDriveSource(_ source: URL, metadata: DriveFile?, record: inout DriveMutationRecord, journal: DriveMutationJournal) throws {
        if kind == .move {
            if source.isFileURL {
                guard JobJournal.Fingerprint(source) == record.fingerprint else { throw DriveMutationError.sourceChanged }
            } else if let provider = RemoteFS.provider(for: source) as? DriveProvider, let client = provider.client, let metadata {
                let fresh = try DriveProvider.wait { try await client.file(metadata.id) }
                guard fresh.version == record.revision else { throw DriveMutationError.sourceChanged }
            } else {
                // Re-read the legacy provider source before deletion; only the uploaded byte identity authorizes removal.
                guard let expected = record.result?.md5Checksum else { throw DriveMutationError.uncertain }
                let scratch = try Self.temporaryFolder()
                defer { try? FileManager.default.removeItem(at: scratch) }
                guard let local = try RemoteFS.provider(for: source)?.download(source, into: scratch), try DriveClient.md5(local) == expected else {
                    throw DriveMutationError.sourceChanged
                }
            }
            record.phase = .sourceRemovalPending; try journal.save(record)
            try removeOriginal(source)
        }
        record.phase = .done; try journal.save(record)
    }
}
