import Foundation
import PorpoiseCore

/// Searches a folder with the bundled fd (names) and ripgrep (contents). Results stream in while the tools run:
/// they're read on threads of their own, loaded off the main thread, and handed over in batches.
final class FolderSearch: @unchecked Sendable {
    struct Tools {
        let fd: String
        let rg: String
    }

    /// The tools in Contents/Helpers (fetched by scripts/fetch-search-tools.sh). Only those: other versions on the
    /// PATH might take other options. Without them the search walks the folders itself.
    static var tools: Tools? {
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let fd = helpers.appendingPathComponent("fd").path, rg = helpers.appendingPathComponent("rg").path
        guard FileManager.default.isExecutableFile(atPath: fd), FileManager.default.isExecutableFile(atPath: rg) else { return nil }
        return Tools(fd: fd, rg: rg)
    }

    /// How often found items are handed over while the search runs.
    static let batchInterval: TimeInterval = 0.12

    private let text: String
    private let scope: URL
    private let contents: Bool
    private let limit: Int
    private let tools: Tools
    private let update: ([FileItem], Bool) -> Void

    private let lock = NSLock()
    private var processes: [Process] = []
    private var running = 0
    private var seen: Set<String> = []
    private var found: [FileItem] = []
    private var flushPending = false
    /// Folders known to be packages (or not), so each is asked once.
    private var isPackage: [String: Bool] = [:]
    private var stopped = false

    /// `update(items, done)` runs on the main queue with everything found so far.
    init(text: String, scope: URL, contents: Bool, limit: Int, tools: Tools, update: @escaping ([FileItem], Bool) -> Void) {
        self.text = text
        self.scope = scope
        self.contents = contents
        self.limit = limit
        self.tools = tools
        self.update = update
    }

    /// The command lines: names with fd; with `contents`, files containing the text with ripgrep too. Both look for
    /// the text as it is (no pattern syntax), in any case, in hidden and ignored files as well, and print paths
    /// separated by NUL so any name comes through whole.
    var commands: [[String]] {
        let names = [
            tools.fd, "--hidden", "--no-ignore", "--ignore-case", "--fixed-strings", "--absolute-path", "--print0",
            "--max-results", String(limit), "--", text, scope.path,
        ]
        let inside = [
            tools.rg, "--files-with-matches", "--null", "--ignore-case", "--fixed-strings", "--hidden", "--no-ignore",
            "--max-filesize", "5M", "--no-messages", "--", text, scope.path,
        ]
        return contents ? [names, inside] : [names]
    }

    func start() {
        for command in commands {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: command[0])
            p.arguments = Array(command.dropFirst())
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { continue }
            lock.withLock {
                processes.append(p)
                running += 1
            }
            // A thread of its own: blocking reads on shared dispatch threads can starve (see Shell).
            Thread { [self] in read(out.fileHandleForReading, of: p) }.start()
        }
        if lock.withLock({ running == 0 }) { DispatchQueue.main.async { [self] in finish() } }
    }

    func stop() {
        let ps = lock.withLock {
            stopped = true
            return processes
        }
        for p in ps where p.isRunning { p.terminate() }
    }

    private func read(_ handle: FileHandle, of process: Process) {
        var rest = Data()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            rest.append(chunk)
            var paths: [String] = []
            while let nul = rest.firstIndex(of: 0) {
                paths.append(String(decoding: rest[rest.startIndex..<nul], as: UTF8.self))
                rest.removeSubrange(rest.startIndex...nul)
            }
            add(paths)
            if lock.withLock({ stopped }) { break }
        }
        process.waitUntilExit()
        let last = lock.withLock {
            running -= 1
            return running == 0
        }
        if last { DispatchQueue.main.async { [self] in finish() } }
    }

    /// Loads the new paths (here, off the main thread) and schedules a batch.
    private func add(_ paths: [String]) {
        let new = lock.withLock { paths.filter { !$0.isEmpty && seen.insert($0).inserted } }.filter { !isInsidePackage($0) }
        let items = new.compactMap { FileItem.load(URL(fileURLWithPath: $0)) }
        let (schedule, full) = lock.withLock { () -> (Bool, Bool) in
            found.append(contentsOf: items.prefix(max(0, limit - found.count)))
            let schedule = !flushPending && !items.isEmpty
            if schedule { flushPending = true }
            return (schedule, found.count >= limit)
        }
        if full { stop() }
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.batchInterval) { [self] in flush(done: false) }
        }
    }

    /// Whether `path` is inside an app or another package below the scope: those are single items (as in Finder),
    /// and their insides aren't results. The package itself is, when its name matches.
    private func isInsidePackage(_ path: String) -> Bool {
        // The tools may print the scope as given or resolved (/var/… or /private/var/…).
        let given = scope.standardizedFileURL.path
        let roots = [given, given.hasPrefix("/private/") ? String(given.dropFirst(8)) : "/private" + given]
        guard let root = roots.first(where: { path.hasPrefix($0 + "/") }) else { return false }
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > root.count, dir.hasPrefix(root) {
            let known = lock.withLock { isPackage[dir] }
            let package =
                known
                ?? {
                    let p = (try? URL(fileURLWithPath: dir).resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
                    lock.withLock { isPackage[dir] = p }
                    return p
                }()
            if package { return true }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return false
    }

    private func flush(done: Bool) {
        let (items, cancelled) = lock.withLock {
            flushPending = false
            return (found, stopped && !done)
        }
        if !cancelled || done { update(items, done) }
    }

    private func finish() {
        if lock.withLock({ stopped && found.count < limit }) { return }  // stopped from outside: nothing more to say
        flush(done: true)
    }
}
