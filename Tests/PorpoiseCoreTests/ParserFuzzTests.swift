import Foundation
import Testing
@testable import PorpoiseCore
import PorpoiseTestSupport

/// Seeded random input for parsers and quoting: pieces of the syntax they read (separators, permissions, dates, numbers
/// at the edges of Int64, quotes, Unicode), joined at random or spliced into valid lines. Same inputs on every run.
struct Fuzzer {
    var rng: SeededGenerator

    init(seed: UInt64) { rng = SeededGenerator(seed: seed) }

    static let atoms: [String] = [
        "\t", "\n", "\r", "\r\n", "\0", " ", "  ", "-", "/", ".", "..", ":", ",", "->", " -> ", "./", "~",
        "d", "l", "r", "w", "x", "s", "S", "t", "T", "c", "b", "p",
        "-rwxr-xr-x", "drwxr-xr-x", "lrwxrwxrwx", "crw-rw-rw-", "-rwsr-sr-t", "dl", "fd", "ff", "lf",
        "0", "1", "7", "9", "42", "-1", "1,", "1, 3", "644", "0755", "99999999999999999999", "9223372036854775807",
        "-9223372036854775808", "1700000000.5", "nan", "inf", "1e400",
        "Jan", "Feb", "Dec", "Foo", "2024-01-05", "12:00", "24:61", "2023", "31", "00:34:40.56",
        "%", "%2e", "%2f", "%00", "%ZZ", "\\", "'", "\"", "`", "$(", ")", "[", "]", "!", "*", "?", "^", "{", "}", "|", "+",
        "é", "e\u{301}", "🐬", "\u{202E}", "\u{FEFF}", "\u{200B}", "한",
        "v", "beta", "Regular File", "Directory", "Symbolic Link", "Character Device", "me", "staff", "root",
        "device", "offline", "model:Pixel_7", "usb:1-1", "List of devices attached",
        "[Color1]", "[Color7Intense]", "[Color9]", "[Color8Intense]", "[Background]", "[Foreground]", "Color=1,2,3",
        "Color=-5,999,x", "Color=", "Input #0, ", "matroska,webm", "Duration: ", "Stream #0:0: Video: h264", "Audio: aac",
        "attached pic", "S3CRET", "secret.txt", "index.m3u8",
    ]

    mutating func int(_ n: Int) -> Int { Int.random(in: 0..<n, using: &rng) }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }

    /// Up to `max` atoms, now and then a random scalar.
    mutating func string(max: Int = 24) -> String {
        var s = ""
        for _ in 0..<int(max + 1) {
            if int(10) == 0 {
                let v = UInt32.random(in: 1...0x1_FFFF, using: &rng)
                if let u = Unicode.Scalar(v) { s.unicodeScalars.append(u) }
            } else {
                s += pick(Self.atoms)
            }
        }
        return s
    }

    /// `s` with a few random edits: delete a run, insert atoms, duplicate a run.
    mutating func mutate(_ s: String) -> String {
        var c = Array(s)
        for _ in 0..<(1 + int(3)) {
            let i = c.isEmpty ? 0 : int(c.count + 1)
            switch int(3) {
            case 0 where !c.isEmpty:
                let len = min(c.count - min(i, c.count - 1), 1 + int(4))
                c.removeSubrange(min(i, c.count - 1)..<min(i, c.count - 1) + len)
            case 1:
                c.insert(contentsOf: Array(string(max: 2)), at: min(i, c.count))
            default:
                guard !c.isEmpty else { continue }
                let a = min(i, c.count - 1), len = min(c.count - a, 1 + int(6))
                c.insert(contentsOf: c[a..<a + len], at: a)
            }
        }
        return String(c)
    }

    /// Random or mutated-from-a-sample text, `lines` records joined by `separator`.
    mutating func text(samples: [String], lines: Int = 6, separator: String = "\n") -> String {
        (0..<(1 + int(lines))).map { _ in int(3) == 0 ? string() : mutate(pick(samples)) }.joined(separator: separator)
    }
}

/// Collects invariant violations so a failure reports a few examples instead of thousands of expectations.
struct Violations {
    private(set) var list: [String] = []
    mutating func check(_ ok: Bool, _ what: @autoclosure () -> String) { if !ok && list.count < 5 { list.append(what()) } }
}

@Suite struct ParserFuzzTests {
    private let cases = 3000
    private let folder = URL(fileURLWithPath: "/remote/folder/")

    private func checkItems(_ items: [FileItem], _ input: String, _ v: inout Violations) {
        for it in items {
            v.check(RemoteParsing.isSafeName(it.name), "unsafe name \(it.name.debugDescription) from \(input.debugDescription)")
            v.check(it.url.deletingLastPathComponent().path == "/remote/folder", "\(it.url.path.debugDescription) outside the folder")
            v.check(it.url.path == "/remote/folder/" + it.name, "url \(it.url.path.debugDescription) for \(it.name.debugDescription)")
            v.check((0...0o7777).contains(it.posixPermissions), "mode \(it.posixPermissions)")
        }
    }

    @Test func remoteListings() {
        var f = Fuzzer(seed: 1)
        var v = Violations()
        let find = ["fd\t4096\t1700000000.5\t755\tme\tstaff\t\t./dir", "ff\t12\t1700000000\t644\tme\tstaff\t\tname\twith tab",
                    "ld\t7\t1700000000\t777\troot\troot\t/tmp\tlink"]
        let stat = ["Directory\t64\t1700000000\t755\tme\tstaff\t\t./dir\n", "Symbolic Link\t3\t1700000000\t755\tme\tstaff\tx\t./l\n",
                    "Regular File\t1\t1700000000\t644\tme\tstaff\t\t./new\nline\n"]
        let ls = ["drwxr-xr-x    2 1000     1000         4096 Jan  5  2024 pub",
                  "-rw-r--r--    1 ftp      ftp       1048576 Oct  7 14:30 big file.iso",
                  "lrwxrwxrwx    1 0        0              11 Mar 12 09:00 latest -> pub/v1.tar",
                  "crw-rw-rw-  1 root root   1,   3 2025-01-01 00:00 null", "-rw-r--r-- 1 user 12 2024-01-05 12:00  two spaces"]
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for _ in 0..<cases {
            let a = f.text(samples: find, separator: f.int(2) == 0 ? "\0" : "\n")
            checkItems(RemoteParsing.parseFind(a, folder: folder), a, &v)
            let b = f.text(samples: stat, separator: "\0")
            checkItems(RemoteParsing.parseBSDStat(b, folder: folder), b, &v)
            let c = f.text(samples: ls, separator: f.int(2) == 0 ? "\n" : "\r\n")
            checkItems(RemoteParsing.parseLsLong(c, folder: folder, now: now, timeZone: .gmt), c, &v)
            let p = f.mutate(f.pick(["-rwxr-xr-x", "drwsr-S--T", "x"]))
            v.check((0...0o7777).contains(RemoteParsing.parsePerms(p)), "perms \(p.debugDescription)")
        }
        #expect(v.list.isEmpty, "\(v.list)")
    }

    @Test func adbDevices() {
        var f = Fuzzer(seed: 2)
        var v = Violations()
        let samples = ["List of devices attached", "emulator-5554 device product:sdk model:Pixel_7 device:emu",
                       "192.168.1.5:5555 device", "R58M offline", "abc unauthorized usb:1-1"]
        for _ in 0..<cases {
            let t = f.text(samples: samples)
            for d in RemoteParsing.parseADBDevices(t) {
                v.check(!d.serial.isEmpty && !d.serial.contains(" ") && !d.serial.contains("\n"), "serial \(d.serial.debugDescription)")
            }
        }
        #expect(v.list.isEmpty, "\(v.list)")
    }

    /// `isNewer` is a strict weak order: irreflexive, antisymmetric, transitive, and "neither is newer" is an
    /// equivalence (so sorting releases by it is well defined).
    @Test func versionOrdering() {
        var f = Fuzzer(seed: 3)
        var v = Violations()
        let parts = ["0", "1", "2", "9", "10", "010", "99999999999999999999", "-1", "a", "beta", "", " "]
        func version() -> String {
            (f.int(4) == 0 ? "v" : "") + (0...f.int(4)).map { _ in f.pick(parts) }.joined(separator: f.int(8) == 0 ? ".." : ".")
        }
        for _ in 0..<cases {
            let a = version(), b = version(), c = version()
            let ab = Version.isNewer(a, than: b), ba = Version.isNewer(b, than: a)
            v.check(!Version.isNewer(a, than: a), "\(a) newer than itself")
            v.check(!(ab && ba), "\(a) and \(b) both newer")
            let bc = Version.isNewer(b, than: c), ac = Version.isNewer(a, than: c)
            v.check(!(ab && bc) || ac, "\(a) > \(b) > \(c) but not \(a) > \(c)")
            if !ab && !ba {
                v.check(ac == bc && Version.isNewer(c, than: a) == Version.isNewer(c, than: b), "\(a) ~ \(b) but they differ against \(c)")
            }
        }
        #expect(v.list.isEmpty, "\(v.list)")
    }

    @Test func nameFilters() throws {
        var f = Fuzzer(seed: 4)
        var v = Violations()
        for _ in 0..<cases {
            let pattern = f.string(max: 8)
            let names = (0..<6).map { _ in f.string(max: 4) }   // short: random regexes may backtrack
            for mode in FilterMode.allCases {
                for cs in [false, true] {
                    guard let m = NameFilter(text: pattern, mode: mode, caseSensitive: cs).matcher() else {
                        v.check(mode != .plainText, "plain text \(pattern.debugDescription) refused")
                        continue
                    }
                    for n in names { _ = m(n) }
                }
            }
            // A glob without wildcards is the name itself: it matches that name and nothing longer.
            let literal = String(pattern.filter { !"*?[".contains($0) })
            if !literal.isEmpty, let m = NameFilter(text: literal, mode: .glob, caseSensitive: true).matcher() {
                v.check(m(literal), "glob \(literal.debugDescription) doesn't match itself")
                v.check(!m(literal + "\n") && !m(literal + "x"), "glob \(literal.debugDescription) matches a longer name")
            } else {
                v.check(literal.isEmpty, "glob \(literal.debugDescription) refused")
            }
            if let m = NameFilter(text: "*", mode: .glob).matcher() {
                v.check(names.allSatisfy(m), "* doesn't match everything")
            }
        }
        #expect(v.list.isEmpty, "\(v.list)")
    }

    @Test func fileFormatting() {
        var f = Fuzzer(seed: 5)
        var v = Violations()
        let edges: [Int64] = [0, 1, 1023, 1024, 1_048_575, 1_048_576, Int64.max, Int64.min, -1, -1024]
        for i in 0..<cases {
            let bytes = i < edges.count ? edges[i] : Int64.random(in: Int64.min...Int64.max, using: &f.rng) >> f.int(64)
            let s = FileFormat.size(bytes)
            v.check(s.hasSuffix("B") && !s.contains("nan") && !s.contains("inf"), "size(\(bytes)) = \(s)")
            v.check(FileFormat.permissions(f.int(1 << 20) - 1000, isDirectory: f.int(2) == 0).count == 10, "permissions")
            _ = FileFormat.summary(folders: f.int(5), files: f.int(5), bytes: bytes, selected: f.int(2) == 0)

            // New names are new, single components, and keep the extension.
            let name = f.int(3) == 0 ? "x (\(f.pick(["9223372036854775807", "99999999999999999999", "-1", "0", "7"]))).txt" : f.string(max: 6)
            guard RemoteParsing.isSafeName(name) else { continue }
            var existing: Set<String> = [name]
            for _ in 0..<3 {
                let d = FileFormat.duplicateName(for: name, existing: existing)
                let g = FileFormat.suggestedName(for: name, existing: existing)
                v.check(!existing.contains(d) && !existing.contains(g), "\(name.debugDescription) → taken name")
                v.check(!d.contains("/") && !g.contains("/"), "\(name.debugDescription) → a path")
                let ext = FileFormat.splitExtension(name).ext
                v.check(ext.isEmpty || (d.hasSuffix("." + ext) && g.hasSuffix("." + ext)), "\(name.debugDescription) lost .\(ext)")
                existing.formUnion([d, g])
            }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for d in [Date.distantPast, .distantFuture, Date(timeIntervalSince1970: -1e11), Date(timeIntervalSince1970: 1e11), now] {
            _ = FileFormat.relativeDate(d, now: now, calendar: cal)
            _ = ItemGrouper.dateGroup(d, now: now, calendar: cal)
        }
        #expect(v.list.isEmpty, "\(v.list)")
    }

    /// Konsole color schemes: whatever the file says, there are 16 colors.
    @Test func konsoleSchemes() {
        var f = Fuzzer(seed: 6)
        let samples = ["[Color0]", "[Color1Intense]", "[Color9]", "[Color8Intense]", "Color=1,2,3", "Color=255, 0 ,9",
                       "[Background]", "[Foreground]", "Color=-1,1e9,3"]
        for _ in 0..<cases {
            #expect(KonsoleScheme.parse(f.text(samples: samples, lines: 40)).palette.count == 16)
        }
        // Sixteen sections that aren't Color0…7 and their Intense versions must not stand in for them.
        var text = ""
        for i in 0..<8 { text += "[Color\(i)]\nColor=\(i),0,0\n" }
        for i in 0..<7 { text += "[Color\(i)Intense]\nColor=\(i),1,0\n" }
        text += "[Color9Intense]\nColor=9,1,0\n"
        #expect(KonsoleScheme.parse(text).palette.count == 16)
    }

    // MARK: Quoting

    /// Undoes `RemoteParsing.quote` the way sh reads it; nil if the word isn't one complete quoted word.
    private func shUnquote(_ q: String) -> String? {
        var out = "", inQuote = false
        var it = q.unicodeScalars.makeIterator()
        while let c = it.next() {
            if inQuote {
                if c == "'" { inQuote = false } else { out.unicodeScalars.append(c) }
            } else if c == "'" {
                inQuote = true
            } else if c == "\\" {
                guard let n = it.next() else { return nil }
                out.unicodeScalars.append(n)
            } else {
                return nil   // anything unquoted could be shell syntax
            }
        }
        return inQuote ? nil : out
    }

    /// Undoes `Escaping.appleScriptString`; nil if a quote ends the literal early or a raw line break is inside.
    private func appleScriptUnquote(_ q: String) -> String? {
        let s = Array(q.unicodeScalars)
        guard s.count >= 2, s.first == "\"", s.last == "\"" else { return nil }
        var out = String.UnicodeScalarView(), i = 1
        while i < s.count - 1 {
            let c = s[i]
            if c == "\"" || c == "\n" || c == "\r" { return nil }
            if c == "\\" {
                i += 1
                guard i < s.count - 1 else { return nil }
                switch s[i] {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "\\", "\"": out.append(s[i])
                default: return nil
                }
            } else {
                out.append(c)
            }
            i += 1
        }
        return String(out)
    }

    @Test func quotingRoundTrips() {
        var f = Fuzzer(seed: 7)
        var v = Violations()
        for _ in 0..<cases {
            let s = f.string()
            v.check(shUnquote(RemoteParsing.quote(s)).map { Array($0.unicodeScalars) } == Array(s.unicodeScalars), "sh \(s.debugDescription)")
            v.check(appleScriptUnquote(Escaping.appleScriptString(s)).map { Array($0.unicodeScalars) } == Array(s.unicodeScalars),
                    "AppleScript \(s.debugDescription)")
        }
        #expect(v.list.isEmpty, "\(v.list)")
    }

    /// A sample of random strings, quoted and read back by a real shell and a real AppleScript: one argument each,
    /// with the same text.
    @Test func quotingRunsForReal() throws {
        var f = Fuzzer(seed: 8)
        let strings = (0..<300).map { _ in String(f.string().unicodeScalars.filter { $0 != "\0" }) }
        let sh = try runTool("/bin/sh", ["-c", strings.map { "set -- \(RemoteParsing.quote($0)); printf '%s:%s\\0' \"$#\" \"$1\"" }.joined(separator: "\n")])
        #expect(sh.status == 0)
        let got = sh.out.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
        #expect(got == strings.map { "1:" + $0 })

        // AppleScript drops a U+FEFF that starts a literal; the app's literals start with "(" (a shell line).
        let texts = strings.prefix(150).map { "(" + $0 }
        var lines = ["set AppleScript's text item delimiters to \",\"", "set out to \"\""]
        lines += texts.map { "set out to out & ((id of \(Escaping.appleScriptString($0))) as text) & linefeed" }
        lines.append("return out")
        let osa = try runTool("/usr/bin/osascript", lines.flatMap { ["-e", $0] })
        #expect(osa.status == 0, "\(String(decoding: osa.err, as: UTF8.self))")
        let back = String(decoding: osa.out, as: UTF8.self).split(separator: "\n").map { line in
            String(String.UnicodeScalarView(line.split(separator: ",").compactMap { UInt32($0).flatMap(Unicode.Scalar.init) }))
        }
        #expect(back == Array(texts))
    }

    /// Random request targets never reach outside the served folder or anything but a regular file in it.
    @Test func servedFileTargets() throws {
        let scratch = try Scratch()
        defer { withExtendedLifetime(scratch) {} }
        try scratch.file("root/stream/index.m3u8", "x")
        try scratch.file("root/.hidden", "x")
        try scratch.file("secret.txt", "x")
        try scratch.symlink("root/stream/out", to: scratch.path("secret.txt").path)
        let root = scratch.path("root").resolvingSymlinksInPath()
        var f = Fuzzer(seed: 9)
        var v = Violations()
        let samples = ["/S3CRET/stream/index.m3u8", "/S3CRET/stream/out", "/S3CRET/../secret.txt", "/S3CRET/.hidden",
                       "/S3CRET/stream/index.m3u8?x=1", "/S3CRET/stream%2Findex.m3u8"]
        var served = 0
        for _ in 0..<cases {
            let t = f.int(4) == 0 ? f.string(max: 10) : f.mutate(f.pick(samples))
            guard let file = Escaping.servedFile(for: t, root: root, secret: "S3CRET") else { continue }
            served += 1
            v.check(file.path.hasPrefix(root.path + "/") && file.lastPathComponent == "index.m3u8", "\(t.debugDescription) → \(file.path)")
        }
        #expect(served > 0)
        #expect(v.list.isEmpty, "\(v.list)")
    }
}
