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

    /// How often found items are handed over while the search runs: often at first, so the first results show at
    /// once, then less often, as each batch makes the view sort and lay out everything found so far again.
    static func batchInterval(found: Int) -> TimeInterval { found < 300 ? 0.12 : found < 2000 ? 0.3 : 0.6 }

    private let text: String
    private let scope: URL
    private let contents: Bool
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

    /// `update(items, snippets, done)` runs on the main queue with everything found so far, and for the files found
    /// by their contents only (not their names), the line that contains the text.
    init(
        text: String, scope: URL, contents: Bool, limit: Int, tools: Tools, update: @escaping ([FileItem], [URL: String], Bool) -> Void
    ) {
        self.text = text
        self.scope = scope
        self.contents = contents
        self.limit = limit
        self.tools = tools
        self.update = update
    }

    /// The command lines: names with fd; with `contents`, files containing the text with ripgrep too. Both look for
    /// the text as it is (no pattern syntax), in any case, in hidden and ignored files as well, and print paths
    /// followed by NUL so any name comes through whole (ripgrep then prints the file's first matching line, cut short
    /// when long; binary files are skipped).
    var commands: [[String]] {
        let names = [
            tools.fd, "--hidden", "--no-ignore", "--ignore-case", "--fixed-strings", "--absolute-path", "--print0",
            "--max-results", String(limit), "--", text, scope.path,
        ]
        let inside = [
            tools.rg, "--max-count", "1", "--null", "--no-heading", "--with-filename", "--no-line-number", "--color", "never",
            "--max-columns", "2000", "--max-columns-preview", "--ignore-case", "--fixed-strings", "--hidden", "--no-ignore",
            "--max-filesize", "5M", "--no-messages", "--", text, scope.path,
        ]
        return contents ? [names, inside] : [names]
    }

    func start() {
        for (n, command) in commands.enumerated() {
            let p = Process()
            // Below the app's own work: a big search keeps the cores busy, the window stays smooth.
            p.qualityOfService = .utility
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
            let withLines = n == 1
            Thread { [self] in read(out.fileHandleForReading, of: p, withLines: withLines) }.start()
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

    /// Reads "path NUL" records, or with `withLines` "path NUL line LF" (ripgrep).
    private func read(_ handle: FileHandle, of process: Process, withLines: Bool) {
        var rest = Data()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            rest.append(chunk)
            var paths: [(path: String, line: String?)] = []
            while let nul = rest.firstIndex(of: 0) {
                let path = String(decoding: rest[rest.startIndex..<nul], as: UTF8.self)
                guard withLines else {
                    paths.append((path, nil))
                    rest.removeSubrange(rest.startIndex...nul)
                    continue
                }
                guard let lf = rest[nul...].firstIndex(of: 10) else { break }  // the line isn't all here yet
                paths.append((path, String(decoding: rest[rest.index(after: nul)..<lf], as: UTF8.self)))
                rest.removeSubrange(rest.startIndex...lf)
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
    private func add(_ paths: [(path: String, line: String?)]) {
        let new = lock.withLock { paths.filter { !$0.path.isEmpty && seen.insert($0.path).inserted } }.filter { !isInsidePackage($0.path) }
        var items: [FileItem] = []
        var lines: [URL: String] = [:]
        for (path, line) in new {
            guard let item = FileItem.load(URL(fileURLWithPath: path)) else { continue }
            items.append(item)
            // Only files whose names don't match get a line: they're the content matches.
            if let line, item.name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                lines[item.url] = Self.snippet(line, around: text)
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
        let (items, lines, cancelled) = lock.withLock {
            flushPending = false
            return (found, snippets, stopped && !done)
        }
        if !cancelled || done { update(items, lines, done) }
    }

    private func finish() {
        if lock.withLock({ stopped && found.count < limit }) { return }  // stopped from outside: nothing more to say
        flush(done: true)
    }
}
