import Foundation
import PorpoiseCore

extension RemoteTransferJob {
    /// Independent small copies share Activity and controls, while each worker owns its journal/conflict state.
    /// Moves, folders, duplicate names, replacements and resumed batches retain the ordered transfer path.
    func runSmallCloudCopies() -> Bool {
        guard kind == .copy, sources.count > 1, completed.isEmpty, let destination, destination.isFileURL else { return false }
        var items: [FileItem] = []
        var names: Set<String> = []
        for source in sources {
            guard let provider = RemoteFS.provider(for: source) as? DriveProvider, let file = provider.metadata(for: source),
                !file.isFolder, !file.isGoogleDocument, file.shortcutDetails == nil, file.version != nil, file.md5Checksum != nil,
                let size = file.size.flatMap(Int64.init), size >= 0, size < 8 * 1024 * 1024,
                let name = RemoteParsing.localName(forRemote: file.name),
                names.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")))
                    .inserted,
                (try? FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(name).path)) == nil
            else { return false }
            items.append(file.fileItem(accountID: provider.accountID))
        }
        progressLock.withLock {
            progress.phase = .transferring
            progress.totalBytes = items.reduce(0) { $0 + $1.size }
            progress.totalFiles = items.count
        }
        onIncoming(nil)
        publish(force: true)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 6
        var snapshots: [URL: JobProgress] = [:]
        for item in items {
            let operation = cloudOperations[item.url] ?? UUID()
            cloudOperations[item.url] = operation
            let child = RemoteTransferJob(kind: .copy, sources: [item.url], destination: destination, control: control, rule: rule, options: options)
            child.cloudBatchID = cloudBatchID
            child.cloudOperations[item.url] = operation
            child.resolve = resolve
            child.onNoSpace = onNoSpace
            child.onNotice = onNotice
            child.onProgress = { snapshot in
                self.progressLock.withLock {
                    snapshots[item.url] = snapshot
                    self.progress.doneBytes = snapshots.values.reduce(0) { $0 + $1.doneBytes }
                    self.progress.doneFiles = snapshots.values.reduce(0) { $0 + $1.doneFiles }
                    self.progress.currentName = snapshot.currentName
                }
                self.publish()
            }
            queue.addOperation {
                child.run(ownsControl: false)
                self.progressLock.withLock {
                    self.results += child.results
                    self.errors += child.errors
                    self.failedSources += child.failedSources
                    self.completed.merge(child.completed) { _, new in new }
                    self.progress.doneItems += 1
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return true
    }
}
