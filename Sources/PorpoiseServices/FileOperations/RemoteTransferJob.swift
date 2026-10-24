import Darwin
import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// One controlled remote batch. Only completed staged files become visible at their final names.
/// All methods run on its worker thread, except the shared thread-safe controls.
final class RemoteTransferJob {
    let control: JobControl
    let kind: FileOperationKind
    let sources: [URL]
    let destination: URL?
    var rule: TransferConflictRule
    var options: TransferCompareOptions
    var resolve: (ConflictInfo) -> ConflictAnswer = { _ in .init(.cancel) }
    var onProgress: (JobProgress) -> Void = { _ in }
    var onNotice: (String?) -> Void = { _ in }
    var onIncoming: (FileItem?) -> Void = { _ in }
    var disposeReplacedItem: ((URL, URL) throws -> Void)?
    var onNoSpace: ((Int64) -> Bool)?
    /// Private consumer copies (sharing) are discarded, never offered as resumable user transfers.
    var temporaryCopy = false
    var cloudBatchID = UUID()
    var cloudOperations: [URL: UUID] = [:]
    var cloudRecovered: [URL: [CloudTransferRecord]] = [:]
    var completed: [URL: URL]
    var results: [URL] = []
    var movedItems: [URL: URL] = [:]
    var errors: [String] = []
    var failures: [TransferFailure] = []
    /// The first error behind `errors`, kept only to be classified for diagnostics.
    var firstError: Error?
    var failedSources: [URL] = []
    var sticky: ConflictResolution?
    var totals: [URL: (bytes: Int64, files: Int)] = [:]
    var progress: JobProgress
    let progressLock = NSLock()
    var committedBytes: Int64 = 0
    var activeBytes: Int64 = 0
    var activeLimit: Int64 = 0
    var activeLegs: Int64 = 1
    var listings: [URL: [FileItem]] = [:]
    var listingIndices: [URL: [String: FileItem]] = [:]
    var publishedNames: [URL: Set<String>] = [:]
    var stageFolders: [URL: URL] = [:]
    var stageJournal: TransferStageJournal?
    var lastPublish = Date.distantPast
    var logicalPaths: [URL: String] = [:]

    func isExcluded(_ url: URL) -> Bool {
        guard !control.policy.exclusions.isEmpty else { return false }
        guard PlacesModel.isCloud(url) else { return control.policy.excludes(url, sources: sources) }
        let path = logicalPaths[url] ?? RemoteFS.displayName(for: url)
        let logical = URL(fileURLWithPath: "/" + path)
        let root = URL(fileURLWithPath: "/" + String(path.split(separator: "/").first ?? ""))
        return control.policy.excludes(logical, sources: [root])
    }

    init(
        kind: FileOperationKind, sources: [URL], destination: URL?, control: JobControl,
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

    func run(ownsControl: Bool = true) {
        // A batch owns its accounts before inventory starts: sign-out must also drain metadata
        // requests and all small-copy children before credentials or caches are removed.
        var ownsAccounts = false
        defer {
            cleanupStages()
            onNotice(nil)
            if ownsControl { control.finish() }
            if ownsAccounts { CloudTransferJournal.shared.release(cloudBatchID) }
        }
        if ownsControl {
            do {
                let accounts = try (sources + [destination].compactMap { $0 }).compactMap { url in
                    try (RemoteFS.provider(for: url) as? CloudTransferProvider)?.transferAccount(url)
                }
                if !accounts.isEmpty {
                    try CloudTransferJournal.shared.claim(cloudBatchID, accounts: accounts, control: control)
                    ownsAccounts = true
                }
            } catch {
                firstError = firstError ?? error
                errors.append(error.localizedDescription)
                failures.append(TransferFailure(source: nil, message: error.localizedDescription))
                failedSources = remaining; return
            }
        }
        let transport = control.asTransferControl(onBytes: { self.advance(bytes: $0) }, onStatus: { self.onNotice($0) })
        Shell.withTransferControl(transport) {
            if runSmallCloudCopies() { return }
            do {
                for source in sources {
                    try control.checkpoint()
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
                    try control.checkpoint()
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
                    if control.isCancelled {
                        if error is CancellationError { break }
                        if case FileOperationError.cancelled = error { break }
                    }
                    failedSources.append(source)
                    let name = RemoteFS.displayName(for: source)
                    firstError = firstError ?? error
                    errors.append("\(name): \(error.localizedDescription)")
                    failures.append(TransferFailure(source: source, message: "\(name): \(error.localizedDescription)"))
                }
                publish()
            }
        }
        publish(force: true)
    }

    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("porpoise-transfer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func children(_ folder: URL, fresh: Bool = false) throws -> [FileItem] {
        try control.checkpoint()
        if !fresh, let cached = listings[folder] { return cached }
        let items: [FileItem]
        if let provider = RemoteFS.provider(for: folder) {
            items = try TransferRetry.run(control: control, notice: onNotice) { try provider.list(folder) }
        } else if folder.isFileURL {
            items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .compactMap(FileItem.load)
        } else {
            throw RemoteError.unsupported("Unsupported location: \(folder.scheme ?? "unknown")")
        }
        listings[folder] = items
        if PlacesModel.isCloud(folder) {
            let parent = logicalPaths[folder] ?? RemoteFS.displayName(for: folder)
            for item in items { logicalPaths[item.url] = parent + "/" + item.name }
        }
        publishedNames[folder] = nil
        listingIndices[folder] = Dictionary(items.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return items
    }

    func item(_ url: URL) throws -> FileItem? {
        if url.isFileURL { return FileItem.load(url) }
        if let cloud = RemoteFS.provider(for: url) as? CloudTransferProvider {
            return try TransferRetry.run(control: control, notice: onNotice) { try cloud.transferItem(url) }
        }
        let folder = url.deletingLastPathComponent()
        if listings[folder] == nil || publishedNames[folder]?.contains(url.lastPathComponent) == true {
            // Upload metadata is provider-dependent. Repeated names must compare against authoritative
            // destination dates/permissions, rather than assuming the source's metadata was preserved.
            _ = try children(folder, fresh: true)
        }
        return listingIndices[folder]?[url.lastPathComponent]
    }

    func inventory(_ url: URL) throws -> (bytes: Int64, files: Int) {
        try control.checkpoint()
        if !control.policy.exclusions.isEmpty, PlacesModel.isCloud(url), logicalPaths[url] == nil, let metadata = try item(url) {
            logicalPaths[url] = metadata.name
        }
        if isExcluded(url) { totals[url] = (0, 0); return (0, 0) }
        guard let item = try item(url) else { return (0, 0) }
        var count = (bytes: item.isSymlink || item.isDirectory ? Int64(0) : item.size, files: item.isDirectory && !item.isSymlink ? 0 : 1)
        if item.isDirectory && !item.isSymlink {
            progressLock.withLock { progress.totalFolders += 1 }
            for child in try children(url) {
                // A transfer is one long work item: what Foundation autoreleases per file goes after each.
                let next = try autoreleasepool { try inventory(child.url) }
                count.bytes += next.bytes; count.files += next.files
            }
        } else {
            progress.totalFiles += 1; progress.totalBytes += count.bytes
        }
        totals[url] = count
        publish()
        return count
    }

    private var moveRemovals: [URL: MoveSourceRemoval] = [:]

    private func captureRemoval(_ source: URL) throws -> MoveSourceRemoval {
        let journal = stageJournal
        return try MoveSourceRemoval(source, cancellation: control.asDiskCancellation(), onCheckpoint: { try journal?.checkpoint($0) })
    }

    func transfer(_ source: URL, into folder: URL) throws -> URL? {
        if isExcluded(source) { control.recordExcluded(source); return nil }
        if kind == .move, let incoming = try item(source), !incoming.isDirectory {
            moveRemovals[source] = try captureRemoval(source)
        }
        if RemoteFS.provider(for: source) is CloudTransferProvider || RemoteFS.provider(for: folder) is CloudTransferProvider {
            return try transferCloud(source, into: folder)
        }
        try control.checkpoint()
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
            let suggestion = FileFormat.suggestedName(for: source.lastPathComponent, existing: Set(try children(folder).map(\.name)))
            switch try conflictDecision(source, incoming: incoming, existing: old, suggestion: suggestion) {
            case .cancel: control.cancel(); throw FileOperationError.cancelled
            case .skip(let identical): skipConflict(source, target: target, identical: identical); return nil
            case .rename(let name):
                try RemoteFS.checkName(name)
                target = folder.appendingPathComponent(name)
            case .merge: return try merge(source, into: target)
            case .replace: replace = true
            case .compareContents: preconditionFailure("Content comparison must be resolved before placement")
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
            remember(incoming, at: target)
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
                cleanupStages()
                guard FileErrorKind.classify(error) == .noSpace, let onNoSpace else {
                    throw error
                }
                progressLock.withLock {
                    activeBytes = 0; progress.doneBytes = committedBytes
                }
                publish(force: true)
                guard onNoSpace(totals[source]?.bytes ?? incoming.size) else { control.cancel(); throw FileOperationError.cancelled }
                try control.checkpoint()
            }
        }
        if replace { progressLock.withLock { progress.replacedItems += 1 } }
        completed[source] = target
        finishProgress(source)
        remember(incoming, at: target)
        return target
    }

    /// Keep path-based destination metadata current without relisting after every published file.
    private func remember(_ incoming: FileItem, at target: URL) {
        let folder = target.deletingLastPathComponent()
        guard listings[folder] != nil else { return }
        let item = FileItem(
            url: target, name: target.lastPathComponent, isDirectory: incoming.isDirectory, isSymlink: incoming.isSymlink,
            size: incoming.size, modificationDate: incoming.modificationDate)
        if listingIndices[folder]?[item.name] == nil {
            listings[folder]?.append(item)
        } else if let index = listings[folder]?.firstIndex(where: { $0.name == item.name }) {
            listings[folder]?[index] = item
        }
        listingIndices[folder]?[item.name] = item
        publishedNames[folder, default: []].insert(item.name)
    }

    private func stagingFolder(for target: URL) throws -> URL {
        let folder = target.deletingLastPathComponent()
        if let stage = stageFolders[folder] { return stage }
        let stage = folder.appendingPathComponent(".porpoise-transfer-" + UUID().uuidString)
        if let provider = RemoteFS.provider(for: target) {
            try provider.makeFolder(stage)
        } else {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do { try stageJournal?.stage(stage) } catch {
                try? FileManager.default.removeItem(at: stage)
                throw error
            }
        }
        stageFolders[folder] = stage
        return stage
    }

    private func cleanupStages() {
        Shell.withoutTransferControl {
            for stage in stageFolders.values {
                if let provider = RemoteFS.provider(for: stage) {
                    try? provider.delete([stage])
                } else {
                    do {
                        try FileManager.default.removeItem(at: stage)
                        try stageJournal?.finish(stage)
                    } catch { stageJournal?.release(stage) }
                }
            }
        }
        stageFolders.removeAll()
    }

    /// The shared remote prompt flow: providers supply metadata and IO, never their own conflict rules.
    func conflictDecision(_ source: URL, incoming: FileItem, existing: FileItem, suggestion: String) throws -> ConflictDecision {
        let policy = ConflictPolicy(source: incoming, destination: existing)
        let answer: ConflictAnswer
        if let choice = policy.automaticResolution(sticky: sticky, rule: rule) {
            answer = .init(choice)
        } else {
            answer = resolve(
                .init(
                    source: incoming, destination: existing, suggestedName: suggestion, comparisonOptions: options,
                    replacedItems: progress.replacedItems, skippedIdenticalItems: progress.skippedIdenticalItems,
                    sourceFolder: policy.isFolderPair
                        ? (try? children(source)).map { TransferFolderSummary(itemCount: $0.count, bytes: totals[source]?.bytes) } : nil,
                    destinationFolder: policy.isFolderPair
                        ? (try? children(existing.url)).map { TransferFolderSummary(itemCount: $0.count) } : nil))
        }
        if let method = answer.comparisonMethod { options.method = method }
        if answer.applyToAll { sticky = answer.resolution }
        let decision = policy.decision(for: answer.resolution, suggestedName: { suggestion }, options: options)
        if decision == .compareContents {
            return try identical(source, incoming, existing.url, existing) ? .skip(identical: true) : .replace
        }
        return decision
    }

    func skipConflict(_ source: URL, target: URL, identical: Bool) {
        if identical { progressLock.withLock { progress.skippedIdenticalItems += 1 } }
        completed[source] = target; finishProgress(source)
    }

    func publishIncoming(_ source: URL, item: FileItem, target: URL) {
        onIncoming(
            FileItem(
                url: target, name: target.lastPathComponent, isDirectory: item.isDirectory, size: totals[source]?.bytes ?? item.size,
                modificationDate: item.modificationDate))
    }

    func merge(_ source: URL, into target: URL) throws -> URL {
        let excludedBefore = control.excludedCount
        let directoryRemoval = kind == .move ? try captureRemoval(source) : nil
        if sources.contains(source), let incoming = try item(source) { publishIncoming(source, item: incoming, target: target) }
        var firstFailure: Error?
        for child in try children(source) {
            do { _ = try autoreleasepool { try transfer(child.url, into: target) } } catch {
                if control.isCancelled || control.isInterrupted { throw error }
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
        // Never recursively delete a moved source folder: it may contain skipped or newly created items.
        if kind == .move && control.excludedCount == excludedBefore {
            if source.isFileURL {
                try directoryRemoval?.local?.removeEmptyDirectory()
            } else {
                guard try children(source, fresh: true).isEmpty, let receipt = directoryRemoval?.remote else {
                    throw RemoteError.failed(
                        "Copy published; source folder retained because it changed or safe generation-bound removal is unavailable.")
                }
                try Shell.withoutTransferControl { try receipt.removeSource() }
            }
            movedItems[source] = target
        }
        completed[source] = target
        return target
    }

    func identical(_ source: URL, _ incoming: FileItem, _ target: URL, _ old: FileItem) throws -> Bool {
        if incoming.isWebDocument || old.isWebDocument { return false }
        let sourceChecksum = try (RemoteFS.provider(for: source) as? CloudTransferProvider)?.transferChecksum(source)
        let targetChecksum = try (RemoteFS.provider(for: target) as? CloudTransferProvider)?.transferChecksum(target)
        if let sourceChecksum, let targetChecksum, sourceChecksum.algorithm == targetChecksum.algorithm {
            return sourceChecksum == targetChecksum && incoming.size == old.size
        }
        if let sourceChecksum, target.isFileURL { return try sourceChecksum.verify(target) }
        if let targetChecksum, source.isFileURL { return try targetChecksum.verify(source) }
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

    func digest(_ url: URL) throws -> String {
        let scratch = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let local = try RemoteFS.provider(for: url)?.download(url, into: scratch) ?? url
        return try FileChecksums.digest(local, cancellation: control.asDiskCancellation())
    }

    func stagedFile(
        _ source: URL, to target: URL, replacing: Bool, modified: Date?, beforeSourceRemoval: (() throws -> Void)? = nil,
        sourceDownloadOperationID: UUID? = nil, sourceRemovalHandled: Bool = false
    ) throws {
        if let native = RemoteFS.provider(for: target) as? RemoteTransferNativeCopy {
            let preserved = replacing && options.method == .sizeAndDate ? modified : nil
            if let result = try native.copyTransferFile(source, to: target, replacing: replacing, modified: preserved) {
                try Shell.withoutTransferControl {
                    try beforeSourceRemoval?()
                    if kind == .move && !sourceRemovalHandled {
                        do { try result.removeSource() } catch {
                            throw RemoteError.failed("Copy published; source removal needs review. \(error.localizedDescription)")
                        }
                        movedItems[source] = target
                    }
                }
                return
            }
        }
        let removal = kind == .move && !sourceRemovalHandled ? (try moveRemovals[source] ?? captureRemoval(source)) : nil
        let destinationStaging = target.isFileURL && !source.isFileURL
        let scratch = destinationStaging ? try stagingFolder(for: target) : try Self.temporaryFolder()
        defer { if !destinationStaging { try? FileManager.default.removeItem(at: scratch) } }
        var downloaded: URL
        if let cloud = RemoteFS.provider(for: source) as? CloudTransferProvider, let operationID = sourceDownloadOperationID {
            downloaded = try TransferRetry.run(control: control, notice: onNotice) {
                try cloud.downloadTransfer(source, into: scratch, operationID: operationID)
            }
        } else {
            downloaded = try TransferRetry.run(control: control, notice: onNotice) {
                guard let provider = RemoteFS.provider(for: source) else { return source }
                let attempt = scratch.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: false)
                do { return try provider.download(source, into: attempt) } catch {
                    try? FileManager.default.removeItem(at: attempt); throw error
                }
            }
        }
        let copiedDigest = removal != nil || replacing ? try FileChecksums.digest(downloaded, cancellation: control.asDiskCancellation()) : nil
        if let provider = RemoteFS.provider(for: target) {
            let stageFolder = try stagingFolder(for: target)
            var staged = stageFolder.appendingPathComponent(downloaded.lastPathComponent)
            var published = false
            defer { if !published { Shell.withoutTransferControl { try? provider.delete([staged]) } } }
            var attempted = false
            try TransferRetry.run(control: control, notice: onNotice) {
                if attempted, try provider.list(stageFolder).contains(where: { $0.name == staged.lastPathComponent }) {
                    // The failed attempt may have left partial bytes. Only this owned, unpublished staging
                    // name is cleared; the visible destination and original remain untouched.
                    try provider.delete([staged])
                }
                attempted = true
                try provider.upload(downloaded, into: stageFolder)
            }
            if staged.lastPathComponent != target.lastPathComponent {
                try provider.rename(staged, to: target.lastPathComponent)
                staged = stageFolder.appendingPathComponent(target.lastPathComponent)
            }
            try control.checkpoint()
            // Publication and removing a moved original form a short non-cancellable commit section. A Stop
            // arriving here leaves this completed item intact and prevents the next item from starting.
            try Shell.withoutTransferControl {
                if replacing {
                    guard let publishing = provider as? RemoteTransferPublishing else {
                        throw RemoteError.unsupported("This server cannot safely replace a file. Keep Both instead.")
                    }
                    do {
                        try publishing.publishTransferFile(staged, to: target, modified: options.method == .sizeAndDate ? modified : nil)
                    } catch is TransferConnectionError {
                        // A rename may have committed before its reply was lost. Never repeat publication.
                        // Reconciliation is part of the commit section; Stop waits for the SSH connection timeout.
                        guard try !provider.list(stageFolder).contains(where: { $0.name == staged.lastPathComponent }),
                            try digest(target) == copiedDigest
                        else { throw TransferConnectionError(message: "Could not verify whether the file was published.") }
                    }
                } else {
                    let exists: Bool
                    if let checking = provider as? RemoteTransferTargetChecking {
                        exists = try checking.transferTargetExists(target)
                    } else {
                        exists = try children(target.deletingLastPathComponent(), fresh: true).contains { $0.name == target.lastPathComponent }
                    }
                    guard !exists else { throw RemoteError.exists(target.lastPathComponent) }
                    try provider.move([staged], into: target.deletingLastPathComponent())
                }
                published = true
            }
            try beforeSourceRemoval?()
            if let removal {
                try control.checkpoint()
                guard let copiedDigest, try digest(target) == copiedDigest else {
                    throw RemoteError.failed("Copy published; source retained because destination verification failed.")
                }
                if let local = removal.local {
                    do { try local.removeSource(afterVerifyingDigest: copiedDigest, target: target) } catch {
                        throw RemoteError.failed("Copy published; source retained. \(error.localizedDescription)")
                    }
                } else {
                    try control.checkpoint()
                    try Shell.withoutTransferControl { try removal.remove(afterVerifying: downloaded) }
                }
                movedItems[source] = target
            }
        } else {
            guard target.isFileURL else { throw RemoteError.unsupported("Unsupported destination.") }
            let stageFolder = try stagingFolder(for: target)
            var removeStage = true
            let staged =
                downloaded.deletingLastPathComponent() == stageFolder || scratch == stageFolder
                ? downloaded : stageFolder.appendingPathComponent(downloaded.lastPathComponent)
            defer { if removeStage { try? FileManager.default.removeItem(at: staged) } }
            if staged != downloaded {
                let copy = FileJob(kind: .copy, sources: [downloaded], destinationFolder: stageFolder)
                var previous: Int64 = 0
                copy.onProgress = { [weak copy] snapshot in
                    do { try self.control.checkpoint() } catch { copy?.cancel() }
                    let next = max(0, snapshot.doneBytes - previous)
                    previous = snapshot.doneBytes
                    self.advance(bytes: next)
                }
                _ = try copy.run()
                if copy.isCancelled { try control.checkpoint() }
                guard copy.errors.isEmpty, copy.denied.isEmpty, !copy.results.isEmpty else {
                    throw RemoteError.failed(copy.errors.first ?? "Could not stage the downloaded file.")
                }
            }
            try control.checkpoint()
            if replacing {
                var info = stat()
                guard lstat(target.path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR else {
                    throw RemoteError.unsupported("A folder cannot be replaced by a remote file. Keep Both instead.")
                }
                // Once swapped, staging may hold the user's previous target. Persist that fact first.
                try stageJournal?.preserve(stageFolder)
                let journal = stageJournal
                do {
                    try FilePublication.replace(
                        staged, at: target,
                        dispose: { previous in
                            if let dispose = disposeReplacedItem {
                                try dispose(previous, target)
                            } else {
                                try FileManager.default.removeItem(at: previous)
                            }
                        }, checkpoint: { try journal?.publicationCheckpoint($0) })
                } catch {
                    if error is FilePublication.Retained {
                        removeStage = false
                        stageFolders[target.deletingLastPathComponent()] = nil
                        stageJournal?.release(stageFolder)
                        throw RemoteError.failed(
                            "The previous item could not be restored automatically. Its staging folder is kept at “\(stageFolder.path)”. \(error.localizedDescription)"
                        )
                    }
                    throw error
                }
            } else {
                do { try FilePublication.renameExclusively(staged, to: target) } catch let error as POSIXError where error.code == .EEXIST {
                    throw RemoteError.exists(target.lastPathComponent)
                }
            }
            try beforeSourceRemoval?()
            if let removal {
                guard try digest(target) == copiedDigest else {
                    throw RemoteError.failed("Copy published; source retained because destination verification failed.")
                }
                try Shell.withoutTransferControl { try removal.remove(afterVerifying: target) }
                movedItems[source] = target
            }
        }
    }

    func removeOriginal(_ source: URL) throws {
        guard let removal = moveRemovals[source] else {
            throw RemoteError.failed("Copy published; source retained because no source generation receipt is available.")
        }
        // Cloud callers already verified the destination receipt. A local receipt still validates
        // the captured bytes and claims the source pathname before deletion.
        let scratch = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let local: URL
        if let provider = RemoteFS.provider(for: source) {
            local = try provider.download(source, into: scratch)
        } else {
            local = scratch.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: local)
        }
        try removal.remove(afterVerifying: local)
    }

    func legCount(_ source: URL) -> Int64 {
        (!source.isFileURL && destination?.isFileURL == false) ? 2 : 1
    }
    func finishProgress(_ source: URL, copied: Bool = false) {
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
    func advance(bytes: Int64) {
        progressLock.withLock {
            guard activeLimit > 0 else { return }
            activeBytes = min(activeLimit, activeBytes + max(0, bytes) / activeLegs)
            progress.doneBytes = min(progress.totalBytes, committedBytes + activeBytes)
        }
        publish()
    }
    func publish(force: Bool = false) {
        let snapshot: JobProgress? = progressLock.withLock {
            guard force || Date().timeIntervalSince(lastPublish) >= 0.25 else { return nil }
            lastPublish = Date()
            return progress
        }
        if let snapshot { onProgress(snapshot) }
    }
}
