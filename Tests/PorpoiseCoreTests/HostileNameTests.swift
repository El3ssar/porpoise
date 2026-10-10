import Foundation
import Testing
@testable import PorpoiseCore
import PorpoiseTestSupport

/// Hostile file names (see `HostileNames`) through the real code paths, on real files: listing, loading, copying,
/// moving, renaming, sorting, and every place a name is quoted for a shell, AppleScript or a URL.
/// Names are compared as bytes: Swift's `==` would let an NFC/NFD mix-up through.
@Suite(.serialized) struct HostileNameTests {
    private let scratch: Scratch
    private let names = HostileNames.all
    private let fm = FileManager.default

    init() throws { scratch = try Scratch("HostileNames") }

    /// One file per name in `folder`, each holding its own index (so contents prove which file is which).
    @discardableResult
    private func populate(_ folder: String) throws -> URL {
        let dir = try scratch.folder(folder)
        for (i, n) in names.enumerated() { try Data("\(i)".utf8).write(to: dir.appendingPathComponent(n)) }
        return dir
    }

    /// Names as stored on disk, read with readdir(3): no Foundation conversion in between. (Foundation itself
    /// writes names decomposed, so "é" in a name created through it is stored as "e" + U+0301.)
    private func nameBytes(in dir: URL) throws -> Set<[UInt8]> {
        guard let d = opendir(dir.path) else { throw CocoaError(.fileReadUnknown) }
        defer { closedir(d) }
        var out = Set<[UInt8]>()
        while let e = readdir(d) {
            let n = withUnsafeBytes(of: e.pointee.d_name) { Array($0.prefix(Int(e.pointee.d_namlen))) }
            if n != [46] && n != [46, 46] { out.insert(n) }
        }
        return out
    }

    /// NUL-terminated records of a tool's output, as text.
    private func nulSeparated(_ d: Data) -> [String] {
        d.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
    }

    private func contents(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    @Test func everyNameIsAValidSafeName() {
        #expect(Set(names.map(bytes)).count == names.count)
        for n in names {
            #expect(FileActions.isValidName(n), "\(n.debugDescription)")
            #expect(RemoteParsing.isSafeName(n), "\(n.debugDescription)")
        }
        for n in [HostileNames.long255Ascii, HostileNames.long255TwoByte, HostileNames.long255Emoji] { #expect(n.utf8.count == 255) }
    }

    @Test func listingAndLoadingKeepNamesExactly() throws {
        let dir = try populate("list")
        let items = try DirectoryLister.list(dir)
        #expect(items.count == names.count)
        #expect(Set(items.map { bytes($0.name) }) == (try nameBytes(in: dir)))
        #expect(Set(items.map { bytes($0.url.lastPathComponent) }) == (try nameBytes(in: dir)))
        for (i, n) in names.enumerated() {
            let url = dir.appendingPathComponent(n)
            let item = try #require(FileItem.load(url), "\(n.debugDescription)")
            #expect(item.name == n, "\(n.debugDescription) → \(item.name.debugDescription)")
            #expect(item.url.lastPathComponent == n)
            #expect(!item.isDirectory && !item.isSymlink && item.size == Int64("\(i)".utf8.count))
            #expect(item.isHidden == n.hasPrefix("."))
            #expect(contents(item.url) == "\(i)")
        }
        #expect(DirectoryLister.childCount(dir, includeHidden: true) == names.count)
        #expect(DirectoryLister.childCount(dir, includeHidden: false) == names.filter { !$0.hasPrefix(".") }.count)
    }

    /// Items keep the folder as the caller named it (through a symlink, too), and an unreadable folder is still the
    /// permission error the folder view explains.
    @Test func listerKeepsTheFolderPathAndPermissionErrors() throws {
        try scratch.file("real/a")
        let link = try scratch.symlink("link", to: scratch.path("real").path)
        #expect(try DirectoryLister.list(link).map(\.url.path) == [link.path + "/a"])
        #expect(try DirectoryLister.list(link)[0].url == link.appendingPathComponent("a"))
        let locked = try scratch.folder("locked")
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o755) }
        #expect {
            try DirectoryLister.list(locked)
        } throws: { ($0 as NSError).code == NSFileReadNoPermissionError }
        #expect(throws: (any Error).self) { try DirectoryLister.list(scratch.path("missing")) }
    }

    @Test func copyMoveAndRenameKeepNamesAndContents() throws {
        let src = try populate("src")
        let dst = try scratch.folder("dst"), moved = try scratch.folder("moved")
        let urls = names.map { src.appendingPathComponent($0) }

        let copy = FileJob(kind: .copy, sources: urls, destinationFolder: dst)
        _ = try copy.run()
        #expect(copy.errors.isEmpty, "\(copy.errors)")
        #expect(try nameBytes(in: dst) == nameBytes(in: src))
        #expect(copy.results.map(\.lastPathComponent) == names)

        let move = FileJob(kind: .move, sources: names.map { dst.appendingPathComponent($0) }, destinationFolder: moved)
        let undo = try #require(try move.run())
        #expect(move.errors.isEmpty, "\(move.errors)")
        #expect(scratch.listing("dst").isEmpty)
        for (i, n) in names.enumerated() { #expect(contents(moved.appendingPathComponent(n)) == "\(i)", "\(n.debugDescription)") }

        // Undo the move: everything is back, byte for byte.
        _ = try FileActions.undo(undo)
        #expect(try nameBytes(in: dst) == nameBytes(in: src))
        #expect(scratch.listing("moved").isEmpty)

        // Rename to another hostile name and back.
        for (i, n) in names.enumerated() {
            let other = n.utf8.count < 255 ? "x" + n : "x" + n.dropFirst()
            let a = dst.appendingPathComponent(n)
            let b = try FileActions.rename(a, to: other)
            #expect(b.lastPathComponent == other)
            #expect(contents(b) == "\(i)")
            let back = try FileActions.rename(b, to: n)
            #expect(back.lastPathComponent == n)
        }
        #expect(try nameBytes(in: dst) == nameBytes(in: src))
    }

    /// A folder with a hostile name full of hostile names, copied as a whole (copyfile's recursive walk).
    @Test func copyingAFolderTreeOfHostileNames() throws {
        let outer = "$(echo PWNED)\n-rf \u{202E}"
        let tree = try scratch.folder("t/\(outer)")
        for (i, n) in names.enumerated() {
            let sub = try scratch.folder("t/\(outer)/\(i % 2 == 0 ? n : "sub")")
            try Data("\(i)".utf8).write(to: sub.appendingPathComponent(i % 2 == 0 ? "f" : n))
        }
        let dst = try scratch.folder("t-dst")
        let job = FileJob(kind: .copy, sources: [tree], destinationFolder: dst)
        _ = try job.run()
        #expect(job.errors.isEmpty, "\(job.errors)")
        let copied = dst.appendingPathComponent(outer)
        for (i, n) in names.enumerated() {
            let f = i % 2 == 0 ? copied.appendingPathComponent(n).appendingPathComponent("f")
                               : copied.appendingPathComponent("sub").appendingPathComponent(n)
            #expect(contents(f) == "\(i)", "\(n.debugDescription)")
        }
    }

    /// Pasting into the same folder makes "name copy…": for the longest names there is no room, which must be an
    /// error naming the file, not a crash or a truncated or mangled name.
    @Test func duplicatesInTheSameFolder() throws {
        let dir = try populate("dup")
        let job = FileJob(kind: .copy, sources: names.map { dir.appendingPathComponent($0) }, destinationFolder: dir)
        _ = try job.run()
        #expect(!job.errors.isEmpty)
        #expect(job.errors.allSatisfy { $0.contains("File name too long") }, "\(job.errors)")
        #expect(job.errors.count + job.results.count == names.count)
        for r in job.results {
            #expect(FileActions.isValidName(r.lastPathComponent))
            #expect(r.lastPathComponent.contains(" copy"))
            #expect(FileJob.itemExists(at: r))
        }
        #expect(try nameBytes(in: dir).count == names.count + job.results.count)
    }

    @Test func duplicateAndSuggestedNamesStayValidAndNew() {
        for n in names {
            var existing: Set<String> = [n]
            for _ in 0..<3 {
                let d = FileFormat.duplicateName(for: n, existing: existing)
                let s = FileFormat.suggestedName(for: n, existing: existing)
                #expect(!existing.contains(d) && !existing.contains(s))
                #expect(!d.contains("/") && !s.contains("/") && d != "." && s != "..")
                existing.insert(d); existing.insert(s)
            }
        }
    }

    /// Sorting: everything comes back once, and the order doesn't depend on the input order.
    @Test func sortingIsAPermutationAndIndependentOfInputOrder() throws {
        let dir = try populate("sort")
        try scratch.folder("sort/-a folder\n")
        let items = try DirectoryLister.list(dir)
        var rng = SeededGenerator(seed: 7)
        for role in ItemRole.allCases {
            for choice in SortingChoice.allCases {
                var p = ViewProperties(); p.sortRole = role; p.hiddenLast = true
                let a = ItemSorter.sort(items, props: p, choice: choice).map(\.url)
                let b = ItemSorter.sort(items.shuffled(using: &rng), props: p, choice: choice).map(\.url)
                #expect(a.count == items.count && Set(a) == Set(items.map(\.url)))
                #expect(a == b, "\(role) \(choice)")
                _ = ItemGrouper.groups(ItemSorter.sort(items, props: p, choice: choice), role: role, props: p, choice: choice)
            }
        }
    }

    // MARK: Shell quoting, by running shells

    /// Each name, quoted, read back by a real shell as `set -- WORD`: exactly one argument, the name itself.
    /// Every sh-compatible shell a remote login might use reads the outer word, so all of them are checked.
    @Test func shellQuotingIsOneWordInEveryShell() throws {
        let script = names.map { "set -- \(RemoteParsing.quote($0)); printf '%s:%s\\0' \"$#\" \"$1\"" }.joined(separator: "\n")
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/ksh"] where fm.isExecutableFile(atPath: shell) {
            let r = try runTool(shell, ["-c", script])
            #expect(r.status == 0, "\(shell): \(String(decoding: r.err, as: UTF8.self))")
            #expect(nulSeparated(r.out) == names.map { "1:" + $0 }, "\(shell)")
        }
    }

    /// Two levels, as SSHProvider does it: `sh -c QUOTED_SCRIPT`, where the script quotes the path again.
    @Test func nestedShellQuoting() throws {
        let inner = names.map { "printf '%s\\0' \(RemoteParsing.quote("./" + $0))" }.joined(separator: "; ")
        let r = try runTool("/bin/sh", ["-c", "sh -c " + RemoteParsing.quote(inner)])
        #expect(r.status == 0)
        #expect(nulSeparated(r.out) == names.map { "./" + $0 })
    }

    /// Quoted paths used as real paths by a shell: `cat` reads the right file for every name.
    @Test func quotedPathsReachTheRightFiles() throws {
        let dir = try populate("cat")
        let script = names.map { "cat -- \(RemoteParsing.quote(dir.appendingPathComponent($0).path)); printf '\\0'" }.joined(separator: "\n")
        let r = try runTool("/bin/sh", ["-c", script])
        #expect(r.status == 0, "\(String(decoding: r.err, as: UTF8.self))")
        #expect(nulSeparated(r.out) == names.indices.map { "\($0)" })
        #expect(scratch.listing("cat").count == names.count)   // nothing created by accident
    }

    // MARK: AppleScript

    /// Every name inside a path, as an AppleScript literal evaluated by osascript: the text comes back unchanged.
    /// (Code points are compared, as `id of`, so line breaks and control characters can't hide in the output.)
    /// A path, as the app quotes them: AppleScript drops a U+FEFF at the very start of a literal.
    @Test func appleScriptLiteralsEvaluateToTheText() throws {
        let texts = (names + [HostileNames.nfc, HostileNames.nfd]).map { "/x/" + $0 }
        var lines = ["set AppleScript's text item delimiters to \",\"", "set out to \"\""]
        for t in texts {
            lines.append("set out to out & ((id of \(Escaping.appleScriptString(t))) as text) & linefeed")
        }
        lines.append("return out")
        let r = try runTool("/usr/bin/osascript", lines.flatMap { ["-e", $0] })
        #expect(r.status == 0, "\(String(decoding: r.err, as: UTF8.self))")
        let got = String(decoding: r.out, as: UTF8.self).split(separator: "\n").map { line in
            String(String.UnicodeScalarView(line.split(separator: ",").compactMap { UInt32($0).flatMap(Unicode.Scalar.init) }))
        }
        #expect(got == texts)
    }

    // MARK: Preview server

    /// Percent-encoded requests for hostile names find exactly that file; dot files and backslashes are refused.
    @Test func servedFilesForHostileNames() throws {
        let root = try populate("served/root/s").deletingLastPathComponent()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        for n in names {
            let enc = try #require(n.addingPercentEncoding(withAllowedCharacters: allowed))
            let got = Escaping.servedFile(for: "/K/s/\(enc)?t=1", root: root, secret: "K")
            if n.hasPrefix(".") || n.contains("\\") {
                #expect(got == nil, "\(n.debugDescription)")
            } else {
                #expect(got?.lastPathComponent == n, "\(n.debugDescription)")
            }
        }
    }

    // MARK: Unicode normalization

    /// NFC and NFD spellings are one name on APFS. Foundation stores names decomposed, but files made by other
    /// tools may be stored composed: such a file is listed with its own bytes, loads, copies and renames.
    @Test func composedNamesOnDisk() throws {
        for (i, n) in [HostileNames.nfc, HostileNames.nfd].enumerated() {
            let dir = try scratch.folder("norm\(i)")
            let fd = open(dir.path + "/" + n, O_CREAT | O_WRONLY, 0o644)   // the bytes of `n`, no Foundation in between
            #expect(fd >= 0); close(fd)
            #expect(try nameBytes(in: dir) == [bytes(n)])
            let listed = try DirectoryLister.list(dir)
            #expect(listed.map { bytes($0.name) } == [bytes(n)])
            #expect(listed.first.flatMap { FileItem.load($0.url) } != nil)
            let other = i == 0 ? HostileNames.nfd : HostileNames.nfc
            #expect(FileJob.itemExists(at: dir.appendingPathComponent(other)))
            let dst = try scratch.folder("norm\(i)-dst")
            let job = FileJob(kind: .copy, sources: listed.map(\.url), destinationFolder: dst)
            _ = try job.run()
            #expect(job.errors.isEmpty)
            #expect(try DirectoryLister.list(dst).map(\.name) == [n])
            // Renaming to the other spelling is not "already exists": it is the same file.
            let r = try FileActions.rename(listed[0].url, to: other)
            #expect(FileJob.itemExists(at: r))
            #expect(try DirectoryLister.list(dir).count == 1)
        }
    }

    // MARK: Dot components and deep paths

    /// "." and ".." inside the URLs handed to a job: the same folder is still recognised as the same folder.
    @Test func dotComponentsInURLs() throws {
        let dir = try scratch.folder("dots")
        try Data("x".utf8).write(to: dir.appendingPathComponent("n.txt"))
        try scratch.folder("dots/sub/inner")
        let viaDot = URL(fileURLWithPath: dir.path + "/./sub/../")
        // Paste into the same folder named differently: a duplicate, not an overwrite of itself.
        let paste = FileJob(kind: .copy, sources: [URL(fileURLWithPath: dir.path + "/./n.txt")], destinationFolder: viaDot)
        _ = try paste.run()
        #expect(paste.errors.isEmpty, "\(paste.errors)")
        #expect(scratch.listing("dots") == ["n copy.txt", "n.txt", "sub"])
        // Copying a folder into itself through "..": refused.
        let into = FileJob(kind: .copy, sources: [dir.appendingPathComponent("sub")],
                           destinationFolder: URL(fileURLWithPath: dir.path + "/sub/inner/.."))
        _ = try into.run()
        #expect(into.errors.count == 1)
        #expect(scratch.listing("dots/sub") == ["inner"])
        // Moving into the folder it is already in, spelled with ".": nothing happens.
        let move = FileJob(kind: .move, sources: [dir.appendingPathComponent("n.txt")], destinationFolder: URL(fileURLWithPath: dir.path + "/."))
        _ = try move.run()
        #expect(move.errors.isEmpty)
        #expect(scratch.listing("dots") == ["n copy.txt", "n.txt", "sub"])
    }

    /// A path just under PATH_MAX (1024) is listed, loaded and copied; a tree deeper than PATH_MAX (made with
    /// relative paths) fails to copy with an error and leaves nothing behind.
    @Test func deepPaths() throws {
        let segment = String(repeating: "d", count: 200)
        var deep = scratch.path("deep/s")
        while deep.path.utf8.count + 201 < 1000 { deep.appendPathComponent(segment) }
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        let leafName = String(repeating: "f", count: 1010 - deep.path.utf8.count - 1)
        try Data("leaf".utf8).write(to: deep.appendingPathComponent(leafName))
        #expect(deep.appendingPathComponent(leafName).path.utf8.count == 1010)
        #expect(try DirectoryLister.list(deep).map(\.name) == [leafName])
        #expect(FileItem.load(deep.appendingPathComponent(leafName))?.size == 4)
        // Copy s → deep/t: the copy's paths are the same length.
        let t = try scratch.folder("deep/t")
        let job = FileJob(kind: .copy, sources: [scratch.path("deep/s")], destinationFolder: t)
        _ = try job.run()
        #expect(job.errors.isEmpty, "\(job.errors)")
        #expect(FileJob.diskSize(t) == 4)

        // Past PATH_MAX: built one relative step at a time.
        let over = try scratch.folder("over/x")
        let mk = try runTool("/bin/sh", ["-c", "for i in 1 2 3 4 5 6; do mkdir \(segment) && cd \(segment) || exit 1; done; echo hi > f"], cwd: over)
        #expect(mk.status == 0)
        #expect(try DirectoryLister.list(over).count == 1)
        #expect(FileJob.diskSize(over) >= 0)   // must not crash
        let dst = try scratch.folder("over/dst-with-a-longer-name")
        let deepCopy = FileJob(kind: .copy, sources: [over], destinationFolder: dst)
        _ = try deepCopy.run()
        // Either copied completely or failed cleanly; never a partial tree reported as success.
        if deepCopy.errors.isEmpty {
            let check = try runTool("/bin/sh", ["-c", "cd x && for i in 1 2 3 4 5 6; do cd \(segment) || exit 1; done; cat f"], cwd: dst)
            #expect(String(decoding: check.out, as: UTF8.self) == "hi\n")
        } else {
            #expect(scratch.listing("over/dst-with-a-longer-name").isEmpty)
        }
        // Scratch removes it with FileManager; make sure that works for trees past PATH_MAX too.
        try runTool("/bin/rm", ["-rf", scratch.path("over").path])
    }
}
