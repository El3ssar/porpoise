import Foundation
import PorpoiseCore

extension RemoteTransferJob {
    /// Shared conflict/progress flow for providers whose locations contain IDs rather than child paths.
    func transferCloud(_ source: URL, into folder: URL) throws -> URL? {
        if let target = completed[source] { finishProgress(source); return target }
        try control.checkCancellation()
        guard let incoming = try item(source) else { throw CloudContentError.notFound }
        let sourceProvider = RemoteFS.provider(for: source) as? CloudTransferProvider
        let targetProvider = RemoteFS.provider(for: folder) as? CloudTransferProvider
        let revision = sourceProvider?.transferRevision(source)
        let operation = cloudOperations[source] ?? UUID(); cloudOperations[source] = operation
        var name = incoming.name
        if folder.isFileURL { name = try RemoteFS.localName(name) }
        var matches = try children(folder, fresh: true).filter { $0.name == name }
        guard matches.count <= 1 else { throw CloudEditError.denied("Several items have this name. Choose a different destination.") }
        var existing = matches.first; var replace = false
        while let old = existing {
            if kind == .move, old.url == source { completed[source] = source; finishProgress(source); return source }
            let bothFolders = incoming.isDirectory && old.isDirectory
            let suggestion = FileFormat.suggestedName(for: name, existing: Set(try children(folder).map(\.name)))
            let answer =
                (sticky ?? rule.resolution).map { ConflictAnswer($0) }
                ?? resolve(.init(source: incoming, destination: old, suggestedName: suggestion, comparisonOptions: options))
            if let method = answer.comparisonMethod { options.method = method }
            if answer.applyToAll { sticky = answer.resolution }
            switch answer.resolution {
            case .cancel: control.cancel(); throw FileOperationError.cancelled
            case .skip: completed[source] = old.url; finishProgress(source); return nil
            case .keepBoth: name = suggestion
            case .rename(let chosen): try RemoteFS.checkName(chosen); name = chosen
            case .writeInto:
                guard bothFolders else { throw CloudEditError.notSupported }; return try merge(source, into: old.url)
            case .overwriteIfDifferent:
                if bothFolders { return try merge(source, into: old.url) }
                if try identical(source, incoming, old.url, old) { finishProgress(source); completed[source] = old.url; return nil }; replace = true
            case .overwriteIfOlder, .overwriteIfLarger:
                if bothFolders { return try merge(source, into: old.url) }
                guard answer.resolution.shouldReplace(source: incoming, destination: old, options: options) else {
                    finishProgress(source); completed[source] = old.url; return nil
                }; replace = true
            case .overwrite:
                if bothFolders { return try merge(source, into: old.url) }; replace = true
            }
            if replace { break }
            matches = try children(folder, fresh: true).filter { $0.name == name }
            guard matches.count <= 1 else { throw CloudEditError.notSupported }; existing = matches.first
        }
        let targetRevision = existing.flatMap { targetProvider?.transferRevision($0.url) }
        let target: URL
        progressLock.withLock {
            progress.currentName = incoming.name; activeLimit = totals[source]?.bytes ?? incoming.size; activeLegs = legCount(source); activeBytes = 0
        }
        if !replace, let result = try targetProvider?.nativeTransfer(source, into: folder, named: name, move: kind == .move, operationID: operation) {
            target = result.url
        } else if incoming.isDirectory {
            guard !replace else { throw CloudEditError.notSupported }
            if let provider = targetProvider {
                target = try provider.createTransferFolder(named: name, in: folder, operationID: operation).url
            } else if folder.isFileURL {
                target = folder.appendingPathComponent(name); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            } else {
                throw CloudEditError.notSupported
            }
            return try merge(source, into: target)
        } else if let provider = targetProvider {
            guard !incoming.isSymlink else { throw CloudEditError.notSupported }
            let scratch = try Self.temporaryFolder(); defer { try? FileManager.default.removeItem(at: scratch) }
            let local: URL
            if let sourceProvider {
                local = try sourceProvider.downloadTransfer(source, into: scratch, operationID: operation)
            } else {
                local = try RemoteFS.provider(for: source)?.download(source, into: scratch) ?? source
            }
            let result = try provider.uploadTransfer(
                local, in: folder, named: name, replacing: replace ? existing?.url : nil, expectedRevision: targetRevision, operationID: operation)
            target = result.url
            if kind == .move {
                if let sourceProvider { try sourceProvider.removeTransferredSource(source, revision: revision) } else { try removeOriginal(source) }
            }
        } else if folder.isFileURL {
            target = folder.appendingPathComponent(name)
            try stagedFile(
                source, to: target, replacing: replace, modified: incoming.modificationDate,
                beforeSourceRemoval: kind == .move
                    ? sourceProvider.map { provider in { try provider.removeTransferredSource(source, revision: revision) } } : nil,
                sourceDownloadOperationID: operation, sourceRemovalHandled: kind == .move && sourceProvider != nil)
        } else {
            throw CloudEditError.denied("Copy through a local folder for this provider combination.")
        }
        completed[source] = target; listings[folder] = nil
        if replace { progressLock.withLock { progress.replacedItems += 1 } }
        finishProgress(source, copied: true); return target
    }
}
