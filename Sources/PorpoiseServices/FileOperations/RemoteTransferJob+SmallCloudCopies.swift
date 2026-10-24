import Foundation
import PorpoiseCore

extension RemoteTransferJob {
    /// Independent small copies share Activity and controls, while each worker owns its journal/conflict state.
    /// Moves, folders, duplicate names, replacements and resumed batches retain the ordered transfer path.
    func runSmallCloudCopies() -> Bool {
        guard control.policy.exclusions.isEmpty else { return false }
        guard kind == .copy, sources.count > 1, completed.isEmpty, let destination, destination.isFileURL else { return false }
        var items: [FileItem] = []
        var names: Set<String> = []
        for source in sources {
            guard let provider = RemoteFS.provider(for: source) as? CloudTransferProvider, let item = provider.smallTransferItem(source),
                let name = RemoteParsing.localName(forRemote: item.name),
                names.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")))
                    .inserted,
                (try? FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(name).path)) == nil
            else { return false }
            items.append(item)
        }
        progressLock.withLock {
            progress.phase = .transferring
            progress.totalBytes = items.reduce(0) { $0 + $1.size }
            progress.totalFiles = items.count
        }
        onIncoming(nil)
        publish(force: true)
        var children: [RemoteTransferJob] = []
        var snapshots: [URL: JobProgress] = [:]
        for item in items {
            let operation = cloudOperations[item.url] ?? UUID()
            cloudOperations[item.url] = operation
            let child = RemoteTransferJob(kind: .copy, sources: [item.url], destination: destination, control: control, rule: rule, options: options)
            child.temporaryCopy = temporaryCopy
            child.cloudBatchID = cloudBatchID
            child.cloudOperations[item.url] = operation
            child.disposeReplacedItem = disposeReplacedItem
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
            children.append(child)
        }
        let nextLock = NSLock(); var next = 0
        // Workers of their own, not concurrentPerform: each one mostly waits on the network, and concurrentPerform's
        // helpers come from the CPU-bounded dispatch pool, so a busy process (CI's 3-core runner) copied one at a time.
        let workers = DispatchGroup()
        func work() {
            while let child = nextLock.withLock({ () -> RemoteTransferJob? in
                guard next < children.count else { return nil }; defer { next += 1 }; return children[next]
            }) {
                child.run(ownsControl: false)
                self.progressLock.withLock {
                    self.results += child.results
                    self.errors += child.errors
                    self.failures += child.failures
                    self.firstError = self.firstError ?? child.firstError
                    self.failedSources += child.failedSources
                    self.completed.merge(child.completed) { _, new in new }
                    self.progress.doneItems += 1
                }
            }
        }
        for _ in 1..<min(6, children.count) {
            workers.enter()
            Thread {
                work(); workers.leave()
            }.start()
        }
        work()
        workers.wait()
        return true
    }
}
