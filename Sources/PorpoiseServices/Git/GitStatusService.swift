import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// A snapshot plus the lexical-to-physical folder mapping, resolved off the main thread once per subscription.
public struct GitFolderStatus: Sendable {
    public let root: URL
    public let folder: URL
    public let resolvedFolder: URL
    public let snapshot: GitStatusSnapshot
    public let isPaused: Bool
    public let caseSensitive: Bool
    public var statusText: String { isPaused ? "Git status paused — Reload to retry" : snapshot.branchText }
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
        guard let prefixRange = physical.range(of: base, options: caseSensitive ? [.anchored] : [.anchored, .caseInsensitive]) else { return nil }
        let relative = String(physical[prefixRange.upperBound...])
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
    public func retry() { GitStatusService.shared.retry(id) }
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
        let caseSensitive: Bool
        var gitDirectories: [URL] = []
        var refreshState = GitRefreshState()
        var scans = 0
        var listeners: [UUID: Listener] = [:]
        var snapshot: GitStatusSnapshot?
        var watcher: FolderWatcher?
        var pending: DispatchWorkItem?
        init(root: URL, caseSensitive: Bool) { self.root = root; self.caseSensitive = caseSensitive }
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
                guard try resolved.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else { throw GitCommand.Failure.command }
                // Ordinary folders need no subprocess; .git can be a directory or a worktree/submodule pointer.
                var candidate = resolved
                while !FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                    let parent = candidate.deletingLastPathComponent()
                    guard parent != candidate else { throw GitCommand.Failure.command }
                    candidate = parent
                }
                try Self.validateLocalMetadata(candidate.appendingPathComponent(".git"))
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
                for directory in [gitDir, commonDir] {
                    guard try directory.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else { throw GitCommand.Failure.command }
                }
                let caseSensitive =
                    (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? true
                let repository = Repository(root: root, caseSensitive: caseSensitive)
                repository.gitDirectories = [gitDir, commonDir]
                repository.listeners[observation.id] = listener; self.repositories[root] = repository
                repository.watcher = FolderWatcher(recursive: true, reportEventPaths: true) { [weak self, weak repository] paths in
                    guard let self else { return }
                    self.queue.async { [weak repository] in
                        guard let repository, self.relevant(paths, for: repository) else { return }; self.schedule(repository)
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
    /// Inspect Git pointer files before invoking Git so a local worktree cannot redirect metadata to a network volume.
    private static func validateLocalMetadata(_ marker: URL) throws {
        func local(_ url: URL) throws {
            guard try url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else { throw GitCommand.Failure.command }
        }
        func pointer(_ file: URL, prefix: String = "", relativeTo parent: URL) throws -> URL {
            try local(file)
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            let data = try handle.read(upToCount: 65537) ?? Data()
            guard data.count <= 65536, !data.contains(0), var path = String(data: data, encoding: .utf8), path.hasPrefix(prefix) else {
                throw GitCommand.Failure.command
            }
            if path.hasSuffix("\n") { path.removeLast() }
            path = String(path.dropFirst(prefix.count))
            guard !path.isEmpty else { throw GitCommand.Failure.command }
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : parent.appendingPathComponent(path)
        }
        try local(marker)
        let isDirectory = try marker.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let directory = try isDirectory ? marker : pointer(marker, prefix: "gitdir: ", relativeTo: marker.deletingLastPathComponent())
        try local(directory)
        let common = directory.appendingPathComponent("commondir")
        if FileManager.default.fileExists(atPath: common.path) { try local(pointer(common, relativeTo: directory)) }
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
    fileprivate func retry(_ id: UUID) {
        queue.async {
            for repository in self.repositories.values where repository.listeners[id] != nil {
                repository.refreshState.resume(); self.schedule(repository)
            }
        }
    }
    // Kept internal for sustained-event regression measurements; no filenames or diagnostics are emitted.
    func scanCount(for root: URL, receive: @escaping (Int) -> Void) {
        queue.async {
            let count = self.repositories[root]?.scans ?? 0; DispatchQueue.main.async { receive(count) }
        }
    }
    private func relevant(_ paths: Set<String>, for repository: Repository) -> Bool {
        paths.contains { path in
            let name = (path as NSString).lastPathComponent
            if name == ".gitignore" || name == ".gitattributes" { return true }
            for git in repository.gitDirectories {
                for noise in ["objects", "logs"] {
                    let prefix = git.path + "/" + noise
                    if path == prefix || path.hasPrefix(prefix + "/") { return false }
                }
            }
            let prefix = repository.root.path + "/"
            if path.hasPrefix(prefix), repository.snapshot?.status(for: String(path.dropFirst(prefix.count)), directory: false) == .ignored {
                return false
            }
            return true
        }
    }
    private func deliver(_ snapshot: GitStatusSnapshot?, from repository: Repository, to listener: Listener) {
        let value = (snapshot ?? (repository.refreshState.isPaused ? GitStatusSnapshot() : nil)).map {
            GitFolderStatus(
                root: repository.root, folder: listener.folder, resolvedFolder: listener.resolved, snapshot: $0,
                isPaused: repository.refreshState.isPaused, caseSensitive: repository.caseSensitive)
        }
        DispatchQueue.main.async { if listener.observation?.isActive == true { listener.receive(value) } }
    }
    private func schedule(_ repository: Repository) {
        repository.pending?.cancel()
        guard let delay = repository.refreshState.delay(at: ProcessInfo.processInfo.systemUptime) else { return }
        let work = DispatchWorkItem { [weak self, weak repository] in
            guard let self, let repository else { return }
            repository.pending = nil; self.refresh(repository, deadline: ProcessInfo.processInfo.systemUptime + Self.budget)
        }
        repository.pending = work; queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func refresh(_ repository: Repository, deadline: TimeInterval) {
        let start = ProcessInfo.processInfo.systemUptime
        repository.scans += 1
        var success = false
        do {
            let preferences = try GitUserPreferences.load(in: repository.root, deadline: deadline)
            let configuration = try preferences.configuration(in: repository.root, deadline: deadline)
            var arguments = ["status", "--porcelain=v2", "-z", "--branch", "--ignore-submodules=none"]
            if !configuration.contains("status.showUntrackedFiles=no") { arguments.append("--ignored=matching") }
            let data = try GitCommand.run(arguments, in: repository.root, deadline: deadline, extraConfiguration: configuration)
            let parsed = try GitStatusParser.parse(data)
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitCommand.Failure.budget }
            repository.snapshot = parsed; success = true
        } catch {
            // Never show an old clean/conflict state after a failed refresh. Back off on pathological repositories.
            repository.snapshot = nil
        }
        repository.refreshState.finished(success: success, start: start, end: ProcessInfo.processInfo.systemUptime)
        for listener in repository.listeners.values { deliver(repository.snapshot, from: repository, to: listener) }
    }
}
