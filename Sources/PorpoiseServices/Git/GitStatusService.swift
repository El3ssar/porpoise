import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// A snapshot plus the lexical-to-physical folder mapping, resolved off the main thread once per subscription.
public struct GitFolderStatus: Sendable {
    public let root: URL
    public let folder: URL
    public let resolvedFolder: URL
    public let snapshot: GitStatusSnapshot
    public func relativePath(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        let physical: String
        if url.path == folder.path {
            physical = resolvedFolder.path
        } else if url.path.hasPrefix(prefix) {
            physical = resolvedFolder.path + "/" + String(url.path.dropFirst(prefix.count))
        } else {
            return nil
        }
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard physical.hasPrefix(base) else { return nil }
        let relative = String(physical.dropFirst(base.count))
        return GitStatusParser.validPath(relative) ? relative : nil
    }
    public func status(for item: FileItem) -> GitFileStatus? {
        relativePath(for: item.url).flatMap { snapshot.status(for: $0, directory: item.isDirectory) }
    }
}

/// Cancellation suppresses already-queued delivery as well as removing the repository subscription.
public final class GitStatusObservation: @unchecked Sendable {
    fileprivate let id = UUID()
    private let lock = NSLock()
    private var active = true
    fileprivate var isActive: Bool { lock.withLock { active } }
    public func cancel() {
        let wasActive = lock.withLock {
            let old = active; active = false; return old
        }
        if wasActive { GitStatusService.shared.remove(id) }
    }
    deinit { cancel() }
}

/// One cached status and recursive watcher per repository, shared by panes/columns. Work and debounce live on a serial
/// background queue; only immutable results cross to the main queue. Unobserved repositories are evicted immediately.
public final class GitStatusService: @unchecked Sendable {
    public static let shared = GitStatusService()
    public static let budget: TimeInterval = 2
    public static let debounce: TimeInterval = 0.4
    private let queue = DispatchQueue(label: "porpoise.git-status", qos: .utility, autoreleaseFrequency: .workItem)
    private struct Listener {
        weak var observation: GitStatusObservation?
        let folder: URL
        let resolved: URL
        let receive: (GitFolderStatus?) -> Void
    }
    private final class Repository {
        let root: URL
        var listeners: [UUID: Listener] = [:]
        var snapshot: GitStatusSnapshot?
        var watcher: FolderWatcher?
        var pending: DispatchWorkItem?
        var retryAfter: TimeInterval = 0
        init(root: URL) { self.root = root }
    }
    private var repositories: [URL: Repository] = [:]
    private init() {}

    public func observe(_ folder: URL, receive: @escaping (GitFolderStatus?) -> Void) -> GitStatusObservation {
        let observation = GitStatusObservation()
        guard folder.isFileURL else { return observation }
        queue.async { [self, weak observation] in
            guard let observation, observation.isActive else { return }
            let resolved = URL(fileURLWithPath: FilePath.canonical(folder.path))
            let deadline = ProcessInfo.processInfo.systemUptime + Self.budget
            do {
                // Ordinary folders need no subprocess; .git can be a directory or a worktree/submodule pointer.
                var candidate = resolved
                while !FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                    let parent = candidate.deletingLastPathComponent()
                    guard parent != candidate else { throw GitCommand.Failure.command }
                    candidate = parent
                }
                // Reject mounted network volumes before invoking Git. A normal local folder must report true.
                guard try resolved.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else { throw GitCommand.Failure.command }
                let root = try GitCommand.path(GitCommand.run(["rev-parse", "--show-toplevel"], in: resolved, deadline: deadline))
                let listener = Listener(observation: observation, folder: folder, resolved: resolved, receive: receive)
                if let repository = self.repositories[root] {
                    repository.listeners[observation.id] = listener
                    self.deliver(repository.snapshot, from: repository, to: listener)
                    return
                }
                let gitDir = try GitCommand.path(
                    GitCommand.run(["rev-parse", "--path-format=absolute", "--git-dir"], in: resolved, deadline: deadline))
                let commonDir = try GitCommand.path(
                    GitCommand.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: resolved, deadline: deadline))
                let repository = Repository(root: root)
                repository.listeners[observation.id] = listener; self.repositories[root] = repository
                repository.watcher = FolderWatcher(recursive: true) { [weak self, weak repository] _ in
                    guard let self else { return }
                    self.queue.async { [weak repository] in
                        guard let repository else { return }; self.schedule(repository)
                    }
                }
                repository.watcher?.watch([root, gitDir, commonDir])
                self.refresh(repository, deadline: deadline)
            } catch {
                DispatchQueue.main.async { [weak observation] in if observation?.isActive == true { receive(nil) } }
            }
        }
        return observation
    }
    fileprivate func remove(_ id: UUID) {
        queue.async {
            for (root, repository) in self.repositories {
                repository.listeners.removeValue(forKey: id)
                if repository.listeners.isEmpty {
                    repository.pending?.cancel(); repository.watcher?.stop(); self.repositories.removeValue(forKey: root)
                }
            }
        }
    }
    private func deliver(_ snapshot: GitStatusSnapshot?, from repository: Repository, to listener: Listener) {
        let value = snapshot.map { GitFolderStatus(root: repository.root, folder: listener.folder, resolvedFolder: listener.resolved, snapshot: $0) }
        DispatchQueue.main.async { if listener.observation?.isActive == true { listener.receive(value) } }
    }
    private func schedule(_ repository: Repository) {
        repository.pending?.cancel()
        let delay = max(Self.debounce, repository.retryAfter - ProcessInfo.processInfo.systemUptime)
        let work = DispatchWorkItem { [weak self, weak repository] in
            guard let self, let repository else { return }
            repository.pending = nil; self.refresh(repository, deadline: ProcessInfo.processInfo.systemUptime + Self.budget)
        }
        repository.pending = work; queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func refresh(_ repository: Repository, deadline: TimeInterval) {
        do {
            let data = try GitCommand.run(
                ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignored=matching", "--ignore-submodules=none"],
                in: repository.root, deadline: deadline)
            let parsed = try GitStatusParser.parse(data)
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitCommand.Failure.budget }
            repository.snapshot = parsed
        } catch {
            // Never show an old clean/conflict state after a failed refresh. Back off on pathological repositories.
            repository.snapshot = nil; repository.retryAfter = ProcessInfo.processInfo.systemUptime + 10
        }
        for listener in repository.listeners.values { deliver(repository.snapshot, from: repository, to: listener) }
    }
}
