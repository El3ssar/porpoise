import Foundation
import PorpoiseCore

/// Discovers candidate paths with bundled fd, then applies the shared search specification.
/// Names and bounded content matches stream in batches from a worker thread.
final class FolderSearch: @unchecked Sendable {
    struct Tools {
        let fd: String
    }

    /// The tools in Contents/Helpers (fetched by scripts/fetch-search-tools.sh). Only those: other versions on the
    /// PATH might take other options. Without them the search walks the folders itself.
    static var tools: Tools? {
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let fd = helpers.appendingPathComponent("fd").path
        guard FileManager.default.isExecutableFile(atPath: fd) else { return nil }
        return Tools(fd: fd)
    }

    /// How often found items are handed over while the search runs: often at first, so the first results show at
    /// once, then less often, as each batch makes the view sort and lay out everything found so far again.
    static func batchInterval(found: Int) -> TimeInterval { found < 300 ? 0.12 : found < 2000 ? 0.3 : 0.6 }

    private let spec: SearchSpec
    private let scope: URL
    private let limit: Int
    private let tools: Tools
    private let update: ([FileItem], [URL: String], Bool) -> Void

    private let lock = NSLock()
    private var processes: [Process] = []
    private var running = 0
    private var seen: Set<String> = []
    private var found: [FileItem] = []
    /// The first line containing the text, for each file found by its contents.
    private var snippets: [URL: String] = [:]
    private var flushPending = false
    /// Folders known to be packages (or not), so each is asked once.
    private var isPackage: [String: Bool] = [:]
    private var stopped = false
    /// A tool couldn't start, or was killed: what it would have found is missing, so the search isn't over.
    private var failed = false
    /// Instead of the last update when a tool failed (the caller searches some other way).
    var onFailure: (() -> Void)?

    /// `update(items, snippets, done)` runs on the main queue with everything found so far, and for the files found
    /// by their contents only (not their names), the line that contains the text.
    init(
        spec: SearchSpec, scope: URL, limit: Int, tools: Tools, update: @escaping ([FileItem], [URL: String], Bool) -> Void
    ) {
        self.spec = spec; self.scope = scope; self.limit = limit; self.tools = tools; self.update = update
    }

    /// fd discovers broad candidates. The shared folded/operator predicate runs before the result limit,
    /// since fd's literal matching cannot express diacritic folding or all of the query operators.
    var commands: [[String]] {
        [[tools.fd, "--hidden", "--no-ignore", "--absolute-path", "--print0", "--", "", scope.path]]
    }

    func start() {
        // A fast first tool may finish while the next Process is still launching. Keep startup counted until
        // every launch has been attempted, so that reader cannot publish an early empty completion.
        lock.withLock { running += 1 }
        for command in commands {
            let p = Process()
            // Below the app's own work: a big search keeps the cores busy, the window stays smooth.
            p.qualityOfService = .utility
            p.executableURL = URL(fileURLWithPath: command[0])
            p.arguments = Array(command.dropFirst())
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch {
                NSLog("Folder search: \((command[0] as NSString).lastPathComponent) didn't start: \(error)")
                lock.withLock { failed = true }
                continue
            }
            lock.withLock {
                processes.append(p)
                running += 1
            }
            // A thread of its own: blocking reads on shared dispatch threads can starve (see Shell).
            Thread { [self] in read(out.fileHandleForReading, of: p) }.start()
        }
        let finished = lock.withLock {
            running -= 1; return running == 0
        }
        if finished { DispatchQueue.main.async { [self] in finish() } }
    }

    func stop() {
        let ps = lock.withLock {
            stopped = true
            return processes
        }
        for p in ps where p.isRunning { p.terminate() }
    }

    /// Reads NUL-delimited paths, including names with embedded line breaks.
    private func read(_ handle: FileHandle, of process: Process) {
        var rest = Data()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            rest.append(chunk)
            var paths: [String] = []
            // Records are read through a cursor and dropped once per chunk: removing each from the front of the
            // buffer moved the rest of it every time (quadratic in the records per chunk).
            var start = rest.startIndex
            while let nul = rest[start...].firstIndex(of: 0) {
                let path = String(decoding: rest[start..<nul], as: UTF8.self)
                paths.append(path)
                start = rest.index(after: nul)
            }
            rest.removeSubrange(rest.startIndex..<start)
            add(paths)
            if lock.withLock({ stopped }) { break }
        }
        process.waitUntilExit()
        let last = lock.withLock {
            // Killed, not by `stop()`: its results are cut short. (ripgrep's 1 and 2 are "nothing" and "some folders
            // unreadable": results all the same.)
            if process.terminationReason == .uncaughtSignal && !stopped {
                NSLog("Folder search: \(process.executableURL?.lastPathComponent ?? "tool") ended by signal \(process.terminationStatus)")
                failed = true
            }
            running -= 1
            return running == 0
        }
        if last { DispatchQueue.main.async { [self] in finish() } }
    }

    /// Loads the new paths (here, off the main thread) and schedules a batch.
    private func add(_ paths: [String]) {
        let new = lock.withLock { paths.filter { !$0.isEmpty && seen.insert($0).inserted } }.filter { !isInsidePackage($0) }
        var items: [FileItem] = []
        var lines: [URL: String] = [:]
        let available = lock.withLock { max(0, limit - found.count) }
        for path in new {
            if items.count >= available || lock.withLock({ stopped }) { break }
            guard spec.contents || spec.nameMatches((path as NSString).lastPathComponent),
                let item = FileItem.load(URL(fileURLWithPath: path)), !(spec.contents && item.isBrowsableFolder),
                spec.metadataMatches(path: path, isDirectory: item.isDirectory, size: item.size, modified: item.modificationDate)
            else { continue }
            if spec.nameMatches(item.name) {
                items.append(item)
            } else if spec.contents, let value = IndexFileText.read(path, limit: 5_000_000),
                let line = value.split(separator: "\n", omittingEmptySubsequences: false).first(where: { spec.contentMatches(String($0)) })
            {
                items.append(item); lines[item.url] = Self.snippet(String(line), around: spec.text)
            }
        }
        let (schedule, full, count) = lock.withLock { () -> (Bool, Bool, Int) in
            let taken = items.prefix(max(0, limit - found.count))
            found.append(contentsOf: taken)
            for it in taken { if let l = lines[it.url] { snippets[it.url] = l } }
            let schedule = !flushPending && !taken.isEmpty
            if schedule { flushPending = true }
            return (schedule, found.count >= limit, found.count)
        }
        if full { stop() }
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.batchInterval(found: count)) { [self] in flush(done: false) }
        }
    }

    /// Shared bounded text verification also gives Spotlight results their first matching line.
    static func lines(in paths: [String], spec: SearchSpec) -> [String: String] {
        var out: [String: String] = [:]
        for path in paths {
            guard let value = IndexFileText.read(path, limit: 5_000_000),
                let line = value.split(separator: "\n", omittingEmptySubsequences: false).first(where: { spec.contentMatches(String($0)) })
            else { continue }
            out[path] = snippet(String(line), around: spec.text)
        }
        return out
    }

    /// The part of `line` worth showing: trimmed, starting a little before the text when it's far in.
    static func snippet(_ line: String, around text: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let flat = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard let r = flat.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) else { return String(flat.prefix(200)) }
        let lead = flat.distance(from: flat.startIndex, to: r.lowerBound)
        guard lead > 16 else { return String(flat.prefix(200)) }
        let start = flat.index(r.lowerBound, offsetBy: -12)
        let from = flat[start...].firstIndex(of: " ").map { flat.index(after: $0) } ?? start
        return "…" + String(flat[(from < r.lowerBound ? from : start)...].prefix(200))
    }

    /// Whether `path` is inside an app or another package below the scope: those are single items (as in Finder),
    /// and their insides aren't results. The package itself is, when its name matches.
    private func isInsidePackage(_ path: String) -> Bool {
        let root = FilePath.canonical(scope.path), resolved = FilePath.canonical(path)
        guard resolved != root, FilePath.contains(path: resolved, in: root) else { return false }
        var dir = (resolved as NSString).deletingLastPathComponent
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
        let (items, lines, cancelled) = lock.withLock {
            flushPending = false
            return (found, snippets, stopped && !done)
        }
        if !cancelled || done { update(items, lines, done) }
    }

    private func finish() {
        if lock.withLock({ stopped && found.count < limit }) { return }  // stopped from outside: nothing more to say
        if lock.withLock({ failed }), let onFailure { return onFailure() }
        flush(done: true)
    }
}
