import Darwin
import Foundation
import PorpoiseCore

/// One controlled remote batch. Only completed staged files become visible at their final names.
/// All methods run on its worker thread, except the FileJob's thread-safe controls.
final class RemoteTransferJob {
    let control: FileJob
    let kind: FileOperationKind
    let sources: [URL]
    let destination: URL?
    var rule: TransferConflictRule
    var options: TransferCompareOptions
    var resolve: (ConflictInfo) -> ConflictAnswer = { _ in .init(.cancel) }
    var onProgress: (JobProgress) -> Void = { _ in }
    var onIncoming: (FileItem?) -> Void = { _ in }
    var onNoSpace: ((Int64) -> Bool)?
    var completed: [URL: URL]
    var results: [URL] = []
    var errors: [String] = []
    var failedSources: [URL] = []
    private var sticky: ConflictResolution?
    private var totals: [URL: (bytes: Int64, files: Int)] = [:]
    private var progress: JobProgress
    private let progressLock = NSLock()
    private var committedBytes: Int64 = 0
    private var activeBytes: Int64 = 0
    private var activeLimit: Int64 = 0
    private var activeLegs: Int64 = 1
    private var listings: [URL: [FileItem]] = [:]
    private var lastPublish = Date.distantPast

    init(
        kind: FileOperationKind, sources: [URL], destination: URL?, control: FileJob,
        rule: TransferConflictRule, options: TransferCompareOptions, completed: [URL: URL] = [:]
    ) {
        self.kind = kind; self.sources = sources; self.destination = destination; self.control = control
        self.rule = rule; self.options = options; self.completed = completed
        progress = JobProgress(
            kind: kind, totalBytes: 0, doneBytes: 0, totalItems: sources.count, doneItems: 0,
            currentName: "", destination: destination)
        progress.phase = .preparing
    }

    var remaining: [URL] { sources.filter { completed[$0] == nil } }

    func run() {
        let transport = Shell.TransferControl(
            isPaused: { self.control.isPaused }, isCancelled: { self.control.isCancelled },
            isInterrupted: { self.control.isInterrupted }, onBytes: { self.advance(bytes: $0) })
        Shell.withTransferControl(transport) {
            do {
                for source in sources {
                    try control.checkCancellation()
                    if kind == .copy || kind == .move { _ = try inventory(source) }
                }
            } catch {
                // The per-item execution path reports inventory failures without duplicating them.
                // Missing metadata must not authorize replacement, but other top-level items may still succeed.
            }
            progressLock.withLock { progress.phase = .transferring }
            publish(force: true)
            for source in sources {
                do {
                    try control.checkCancellation()
                    switch kind {
                    case .copy, .move:
                        guard let destination else { continue }
                        if let result = try transfer(source, into: destination) { results.append(result) }
                    case .delete, .trash:
                        if let provider = RemoteFS.provider(for: source) {
                            try provider.delete([source])
                        } else {
                            try FileManager.default.removeItem(at: source)
                        }
                        completed[source] = source
                    case .link: throw RemoteError.unsupported("Links can't be created across remote locations.")
                    }
                    progressLock.withLock { progress.doneItems += 1 }
                } catch {
                    if control.isCancelled { break }
                    failedSources.append(source)
                    errors.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
                publish()
            }
        }
        publish(force: true)
        control.finishExternal()
    }

    private static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-transfer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func children(_ folder: URL, fresh: Bool = false) throws -> [FileItem] {
        try control.checkCancellation()
        if !fresh, let cached = listings[folder] { return cached }
        let items: [FileItem]
        if let provider = RemoteFS.provider(for: folder) {
            items = try provider.list(folder)
        } else if folder.isFileURL {
            items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .compactMap(FileItem.load)
        } else {
            throw RemoteError.unsupported("Unsupported location: \(folder.scheme ?? "unknown")")
        }
        listings[folder] = items
        return items
    }

    private func item(_ url: URL) throws -> FileItem? {
        if url.isFileURL { return FileItem.load(url) }
        return try children(url.deletingLastPathComponent()).first { $0.name == url.lastPathComponent }
    }

    private func inventory(_ url: URL) throws -> (bytes: Int64, files: Int) {
        try control.checkCancellation()
        guard let item = try item(url) else { return (0, 0) }
        var count = (bytes: item.isSymlink || item.isDirectory ? Int64(0) : item.size, files: item.isDirectory && !item.isSymlink ? 0 : 1)
        if item.isDirectory && !item.isSymlink {
            progressLock.withLock { progress.totalFolders += 1 }
            for child in try children(url) {
                let next = try inventory(child.url)
                count.bytes += next.bytes; count.files += next.files
            }
        } else {
            progress.totalFiles += 1; progress.totalBytes += count.bytes
        }
        totals[url] = count
        publish()
        return count
    }

    private func transfer(_ source: URL, into folder: URL) throws -> URL? {
        try control.checkCancellation()
        guard source.isFileURL || RemoteFS.provider(for: source) != nil else {
            throw RemoteError.unsupported("Unsupported source: \(source.scheme ?? "unknown")")
        }
        if let target = completed[source] { finishProgress(source); return target }
        guard let incoming = try item(source) else { throw RemoteError.failed("“\(source.lastPathComponent)” is no longer there.") }
        var target = folder.appendingPathComponent(source.lastPathComponent)
        if kind == .move && source.standardized == target.standardized { completed[source] = target; finishProgress(source); return nil }
        let topLevel = sources.contains(source)
        defer { if topLevel { onIncoming(nil) } }
        var existing = try item(target)
        var replace = false
        while let old = existing {
            let bothFolders = incoming.isDirectory && !incoming.isSymlink && old.isDirectory && !old.isSymlink
            let names = Set(try children(folder).map(\.name))
            let suggestion = FileFormat.suggestedName(for: source.lastPathComponent, existing: names)
            let choice: ConflictResolution
            if let selected = sticky ?? rule.resolution, selected != .writeInto || bothFolders {
                choice = selected
            } else {
                let answer = resolve(
                    .init(
                        source: incoming, destination: old, suggestedName: suggestion, comparisonOptions: options,
                        sourceFolder: bothFolders
                            ? (try? children(source)).map { TransferFolderSummary(itemCount: $0.count, bytes: totals[source]?.bytes) } : nil,
                        destinationFolder: bothFolders ? (try? children(target)).map { TransferFolderSummary(itemCount: $0.count) } : nil))
                if let method = answer.comparisonMethod { options.method = method }
                if answer.applyToAll { sticky = answer.resolution }
                choice = answer.resolution
            }
            switch choice {
            case .cancel: control.cancel(); throw FileOperationError.cancelled
            case .skip: finishProgress(source); completed[source] = target; return nil
            case .keepBoth: target = folder.appendingPathComponent(suggestion)
            case .rename(let name):
                try RemoteFS.checkName(name)
                target = folder.appendingPathComponent(name)
            case .writeInto:
                guard bothFolders else { finishProgress(source); return nil }
                return try merge(source, into: target)
            case .overwriteIfDifferent:
                if bothFolders { return try merge(source, into: target) }
                if try identical(source, incoming, target, old) {
                    progressLock.withLock { progress.skippedIdenticalItems += 1 }
                    finishProgress(source); completed[source] = target; return nil
                }
                replace = true
            case .overwriteIfOlder, .overwriteIfLarger:
                if bothFolders { return try merge(source, into: target) }
                guard choice.shouldReplace(source: incoming, destination: old, options: options) else {
                    finishProgress(source); completed[source] = target; return nil
                }
                replace = true
            case .overwrite:
                if bothFolders { return try merge(source, into: target) }
                replace = true
            }
            if replace { break }
            existing = try item(target)
        }
        if topLevel { publishIncoming(source, item: incoming, target: target) }
        if incoming.isDirectory && !incoming.isSymlink {
            guard !replace else { throw RemoteError.unsupported("A folder cannot replace a file across these locations. Keep Both instead.") }
            if let provider = RemoteFS.provider(for: target) {
                try provider.makeFolder(target)
            } else {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            }
            if totals[source]?.files == 0 { progressLock.withLock { progress.copiedItems += 1 } }
            return try merge(source, into: target)
        }
        guard !incoming.isSymlink else { throw RemoteError.unsupported("Remote link transfers are not supported by this provider.") }
        progressLock.withLock {
            progress.currentName = source.lastPathComponent
            activeLimit = totals[source]?.bytes ?? incoming.size
            activeLegs = legCount(source)
            activeBytes = 0
        }
        while true {
            do { try stagedFile(source, to: target, replacing: replace, modified: incoming.modificationDate); break } catch {
                let message = error.localizedDescription.lowercased()
                guard FileJob.isNoSpace(error) || message.contains("no space left") || message.contains("disk full"), let onNoSpace else {
                    throw error
                }
                progressLock.withLock {
                    activeBytes = 0; progress.doneBytes = committedBytes
                }
                publish(force: true)
                guard onNoSpace(totals[source]?.bytes ?? incoming.size) else { control.cancel(); throw FileOperationError.cancelled }
                try control.checkCancellation()
            }
        }
        if replace { progressLock.withLock { progress.replacedItems += 1 } }
        completed[source] = target
        finishProgress(source)
        listings[folder] = nil
        return target
    }

    private func publishIncoming(_ source: URL, item: FileItem, target: URL) {
        onIncoming(
            FileItem(
                url: target, name: target.lastPathComponent, isDirectory: item.isDirectory, size: totals[source]?.bytes ?? item.size,
                modificationDate: item.modificationDate))
    }

    private func merge(_ source: URL, into target: URL) throws -> URL {
        if sources.contains(source), let incoming = try item(source) { publishIncoming(source, item: incoming, target: target) }
        var firstFailure: Error?
        for child in try children(source) {
            do { _ = try transfer(child.url, into: target) } catch {
                if control.isCancelled || control.isInterrupted { throw error }
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
        // Never recursively delete a moved source folder: it may contain skipped or newly created items.
        if kind == .move {
            if source.isFileURL {
                _ = rmdir(source.path)
            } else if try children(source, fresh: true).isEmpty {
                try Shell.withoutTransferControl { try RemoteFS.provider(for: source)?.removeEmptyFolder(source) }
            }
        }
        completed[source] = target
        return target
    }

    private func identical(_ source: URL, _ incoming: FileItem, _ target: URL, _ old: FileItem) throws -> Bool {
        var left = TransferComparison.entry(incoming), right = TransferComparison.entry(old)
        if options.method == .sizeAndDate {
            if let provider = RemoteFS.provider(for: source) as? RemoteTransferMetadata {
                left.modified = try provider.transferModificationDate(source)
            }
            if let provider = RemoteFS.provider(for: target) as? RemoteTransferMetadata {
                right.modified = try provider.transferModificationDate(target)
            }
        }
        if options.method == .content && left.size == right.size {
            left.hash = try digest(source)
            right.hash = try digest(target)
        }
        return TransferComparator.statusOf(left, right, options: options) == .same
    }

    private func digest(_ url: URL) throws -> String {
        let scratch = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let local = try RemoteFS.provider(for: url)?.download(url, into: scratch) ?? url
        return try FileChecksums.digest(local, cancellation: DiskCancellation(checkpoint: { try self.control.checkCancellation() }))
    }

    private func stagedFile(_ source: URL, to target: URL, replacing: Bool, modified: Date?) throws {
        let scratch = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let downloaded = try RemoteFS.provider(for: source)?.download(source, into: scratch) ?? source
        if let provider = RemoteFS.provider(for: target) {
            let stageFolder = target.deletingLastPathComponent().appendingPathComponent(".porpoise-transfer-" + UUID().uuidString)
            try provider.makeFolder(stageFolder)
            defer { Shell.withoutTransferControl { try? provider.delete([stageFolder]) } }
            try provider.upload(downloaded, into: stageFolder)
            var staged = stageFolder.appendingPathComponent(downloaded.lastPathComponent)
            if staged.lastPathComponent != target.lastPathComponent {
                try provider.rename(staged, to: target.lastPathComponent)
                staged = stageFolder.appendingPathComponent(target.lastPathComponent)
            }
            try control.checkCancellation()
            // Publication and removing a moved original form a short non-cancellable commit section. A Stop
            // arriving here leaves this completed item intact and prevents the next item from starting.
            try Shell.withoutTransferControl {
                if replacing {
                    guard let publishing = provider as? RemoteTransferPublishing else {
                        throw RemoteError.unsupported("This server cannot safely replace a file. Keep Both instead.")
                    }
                    try publishing.publishTransferFile(staged, to: target, modified: options.method == .sizeAndDate ? modified : nil)
                } else {
                    guard try children(target.deletingLastPathComponent(), fresh: true).allSatisfy({ $0.name != target.lastPathComponent }) else {
                        throw RemoteError.exists(target.lastPathComponent)
                    }
                    try provider.move([staged], into: target.deletingLastPathComponent())
                }
                if kind == .move { try removeOriginal(source) }
            }
        } else {
            guard target.isFileURL else { throw RemoteError.unsupported("Unsupported destination.") }
            let stageFolder = target.deletingLastPathComponent().appendingPathComponent(".porpoise-transfer-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: stageFolder, withIntermediateDirectories: false)
            var removeStage = true
            defer { if removeStage { try? FileManager.default.removeItem(at: stageFolder) } }
            let staged = stageFolder.appendingPathComponent(downloaded.lastPathComponent)
            let copy = FileJob(kind: .copy, sources: [downloaded], destinationFolder: stageFolder)
            var previous: Int64 = 0
            copy.onProgress = { [weak copy] snapshot in
                do { try self.control.checkCancellation() } catch { copy?.cancel() }
                let next = max(0, snapshot.doneBytes - previous)
                previous = snapshot.doneBytes
                self.advance(bytes: next)
            }
            _ = try copy.run()
            if copy.isCancelled { try control.checkCancellation() }
            guard copy.errors.isEmpty, copy.denied.isEmpty, !copy.results.isEmpty else {
                throw RemoteError.failed(copy.errors.first ?? "Could not stage the downloaded file.")
            }
            try control.checkCancellation()
            if replacing {
                var info = stat()
                guard lstat(target.path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR else {
                    throw RemoteError.unsupported("A folder cannot be replaced by a remote file. Keep Both instead.")
                }
                guard renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                do {
                    if let dispose = control.disposeReplacedItem {
                        try dispose(staged, target)
                    } else {
                        try FileManager.default.removeItem(at: staged)
                    }
                } catch {
                    guard renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
                        removeStage = false
                        throw RemoteError.failed(
                            "The previous item could not be restored automatically. Its staging folder is kept at “\(stageFolder.path)”. \(error.localizedDescription)"
                        )
                    }
                    throw error
                }
            } else {
                guard renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw RemoteError.exists(target.lastPathComponent) }
            }
            if kind == .move { try Shell.withoutTransferControl { try removeOriginal(source) } }
        }
    }

    private func removeOriginal(_ source: URL) throws {
        if let provider = RemoteFS.provider(for: source) { try provider.delete([source]) } else { try FileManager.default.removeItem(at: source) }
    }

    private func legCount(_ source: URL) -> Int64 {
        (!source.isFileURL && destination?.isFileURL == false) ? 2 : 1
    }
    private func finishProgress(_ source: URL, copied: Bool = false) {
        progressLock.withLock {
            progress.doneFiles += totals[source]?.files ?? 1
            if copied { progress.copiedItems += totals[source]?.files ?? 1 }
            committedBytes += totals[source]?.bytes ?? 0
            activeBytes = 0
            activeLimit = 0
            progress.doneBytes = min(progress.totalBytes, committedBytes)
        }
        publish()
    }
    private func advance(bytes: Int64) {
        progressLock.withLock {
            guard activeLimit > 0 else { return }
            activeBytes = min(activeLimit, activeBytes + max(0, bytes) / activeLegs)
            progress.doneBytes = min(progress.totalBytes, committedBytes + activeBytes)
        }
        publish()
    }
    private func publish(force: Bool = false) {
        let snapshot: JobProgress? = progressLock.withLock {
            guard force || Date().timeIntervalSince(lastPublish) >= 0.25 else { return nil }
            lastPublish = Date()
            return progress
        }
        if let snapshot { onProgress(snapshot) }
    }
}
