import Foundation
import UniformTypeIdentifiers

/// Parsers for remote directory listings (SSH `find -printf`, BSD `stat`, `ls -l` from FTP servers and Android).
///
/// Entry names come from another machine and are untrusted: names that are not a single path component
/// ("", ".", "..", anything with "/" or NUL) are dropped, so a listing can never point outside its folder.
public enum RemoteParsing {

    // MARK: SSH listings

    /// GNU find: `%y%Y\t%s\t%T@\t%m\t%u\t%g\t%l\t%f` (own type + target type, so links to folders browse).
    /// Records end with NUL (`\0`, safe for names containing newlines) or, for older callers, a newline.
    public static func parseFind(_ text: String, folder: URL) -> [FileItem] {
        records(text, statNewlines: false).compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8 else { return nil }
            let type = f[0]
            return item(folder: folder, name: f[7...].joined(separator: "\t"), isDir: type.last == "d",
                        isLink: type.first == "l", size: Int64(f[1]) ?? 0,
                        mtime: Double(f[2]).map { Date(timeIntervalSince1970: $0) }, mode: Int(f[3], radix: 8) ?? 0o644,
                        owner: f[4], group: f[5], link: f[6].isEmpty ? nil : f[6])
        }
    }

    /// BSD stat: `-f '%HT\t%z\t%m\t%Lp\t%Su\t%Sg\t%Y\t%N'` (macOS / FreeBSD servers), records separated
    /// like `parseFind`'s. A link to a folder has its type prefixed with "Directory " (stat alone can't tell).
    public static func parseBSDStat(_ text: String, folder: URL) -> [FileItem] {
        records(text, statNewlines: true).compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8 else { return nil }
            let name = (f[7...].joined(separator: "\t") as NSString).lastPathComponent
            let t = f[0].lowercased()
            return item(folder: folder, name: name, isDir: t.contains("directory"), isLink: t.contains("symbolic"),
                        size: Int64(f[1]) ?? 0, mtime: Double(f[2]).map { Date(timeIntervalSince1970: $0) },
                        mode: Int(f[3], radix: 8) ?? 0o644, owner: f[4], group: f[5], link: f[6].isEmpty ? nil : f[6])
        }
    }

    /// NUL-terminated records when present, else lines. `statNewlines`: each record ends with the newline `stat`
    /// prints before its NUL, which is dropped; find's records end in the name itself, which may end in a newline.
    static func records(_ text: String, statNewlines: Bool) -> [String] {
        if text.contains("\0") {
            return text.split(separator: "\0").map { r in
                var s = String(r)
                if statNewlines, s.hasSuffix("\n") { s.removeLast() }
                return s
            }.filter { !$0.isEmpty }
        }
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: ls -l (FTP, Android)

    /// `ls -l` style lines (FTP LIST, Android toybox `ls -la`). Handles both
    /// `drwxr-xr-x 2 user group 4096 Jan  5 12:00 name` and `drwxr-xr-x 2 user group 4096 2024-01-05 12:00 name`,
    /// a missing group column, and device files (`crw-rw-rw- 1 root root 1,   3 …`).
    /// FTP servers report UTC (pass `.gmt`); Android reports device-local time.
    public static func parseLsLong(_ text: String, folder: URL, now: Date = Date(), timeZone: TimeZone = .current) -> [FileItem] {
        let dates = LsDateParser(now: now, timeZone: timeZone)
        var out: [FileItem] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard let first = line.first, "dl-cbps".contains(first), line.count > 10 else { continue }
            var rest = Substring(line)
            // Whitespace tokens, keeping the remainder intact (the name may contain spaces).
            func nextToken() -> Substring? {
                rest = rest.drop(while: { $0 == " " })
                guard !rest.isEmpty else { return nil }
                let t = rest.prefix(while: { $0 != " " })
                rest = rest.dropFirst(t.count)
                return t
            }
            var tokens: [Substring] = []
            for _ in 0..<5 { if let t = nextToken() { tokens.append(t) } }
            guard tokens.count == 5 else { continue }
            let perms = String(tokens[0])
            let owner = String(tokens[2])
            var group = String(tokens[3])
            var size: Int64 = 0
            var dateTokens: [String] = []
            if tokens[4].hasSuffix(","), Int64(tokens[4].dropLast()) != nil {
                _ = nextToken()   // device file: "major, minor" instead of a size
            } else if tokens[4].contains(","), Int64(tokens[4].split(separator: ",").first ?? "") != nil {
                // "major,minor" written without a space: nothing more to skip.
            } else if let s = Int64(tokens[4]) {
                size = s
            } else if let s = Int64(tokens[3]) {
                // No group column: tokens[4] is already the first date token.
                size = s; group = ""; dateTokens.append(String(tokens[4]))
            } else { continue }
            // Date: "Jan 5 12:00" / "Jan 5 2023" (3 tokens) or "2024-01-05 12:00" (2 tokens).
            if dateTokens.isEmpty, let t = nextToken() { dateTokens.append(String(t)) }
            let remaining = dateTokens.first?.contains("-") == true ? 1 : 3 - dateTokens.count
            for _ in 0..<remaining { if let t = nextToken() { dateTokens.append(String(t)) } }
            // Exactly one space separates the date from the name: a name may itself start with spaces.
            var name = String(rest.hasPrefix(" ") ? rest.dropFirst() : rest)
            var link: String?
            // Only links have " -> target"; for them the first " -> " is the best guess.
            if first == "l", let r = name.range(of: " -> ") {
                link = String(name[r.upperBound...])
                name = String(name[..<r.lowerBound])
            }
            if let it = item(folder: folder, name: name, isDir: first == "d", isLink: first == "l", size: size,
                             mtime: dates.parse(dateTokens), mode: parsePerms(perms), owner: owner, group: group, link: link) {
                out.append(it)
            }
        }
        return out
    }

    /// "rwxr-sr-t" → mode bits, including setuid/setgid/sticky (s/S, t/T).
    public static func parsePerms(_ p: String) -> Int {
        let chars = Array(p.dropFirst().prefix(9))
        guard chars.count == 9 else { return 0o644 }
        let bits = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
        let special = [2: 0o4000, 5: 0o2000, 8: 0o1000]
        var mode = 0
        for (i, c) in chars.enumerated() {
            if c != "-" && c != "S" && c != "T" { mode |= bits[i] }
            if let s = special[i], "sStT".contains(c) { mode |= s }
        }
        return mode
    }

    static func parseLsDate(_ t: [String], now: Date, timeZone: TimeZone = .current) -> Date? {
        LsDateParser(now: now, timeZone: timeZone).parse(t)
    }

    /// Date column of `ls -l`; formatters are built once per listing.
    struct LsDateParser {
        let now: Date
        let year: Int
        let iso: DateFormatter
        let recent: DateFormatter
        let old: DateFormatter

        init(now: Date, timeZone: TimeZone) {
            func make(_ format: String) -> DateFormatter {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = timeZone
                f.dateFormat = format
                return f
            }
            self.now = now
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            year = cal.component(.year, from: now)
            iso = make("yyyy-MM-dd HH:mm")
            recent = make("MMM d yyyy HH:mm")
            old = make("MMM d yyyy")
        }

        func parse(_ t: [String]) -> Date? {
            if t.count >= 2, t[0].contains("-") { return iso.date(from: "\(t[0]) \(t[1].prefix(5))") }
            guard t.count >= 3 else { return nil }
            guard t[2].contains(":") else { return old.date(from: "\(t[0]) \(t[1]) \(t[2])") }
            // Recent files have no year: this year, or last year if that would be in the future.
            guard let d = recent.date(from: "\(t[0]) \(t[1]) \(year) \(t[2])") else { return nil }
            return d > now.addingTimeInterval(86400) ? recent.date(from: "\(t[0]) \(t[1]) \(year - 1) \(t[2])") : d
        }
    }

    // MARK: adb

    /// `adb devices -l` → (serial, model)
    public static func parseADBDevices(_ text: String) -> [(serial: String, model: String)] {
        text.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[1] == "device" else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            return (String(parts[0]), model ?? String(parts[0]))
        }
    }

    // MARK: Helpers

    /// A single, safe path component (see the type's note on untrusted names). Checked by scalar: a "/" followed
    /// by a combining mark is a single Character, which `contains("/")` doesn't find.
    public static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.unicodeScalars.contains { $0 == "/" || $0 == "\0" }
    }

    static func item(folder: URL, name: String, isDir: Bool, isLink: Bool, size: Int64, mtime: Date?, mode: Int,
                     owner: String, group: String, link: String?) -> FileItem? {
        guard isSafeName(name) else { return nil }
        let url = folder.appendingPathComponent(name, isDirectory: isDir)
        let ext = (name as NSString).pathExtension
        let type = isDir ? "public.folder" : (ext.isEmpty ? "public.data" : UTType(filenameExtension: ext)?.identifier ?? "public.data")
        return FileItem(url: url, name: name, isDirectory: isDir, isSymlink: isLink, isHidden: name.hasPrefix("."),
                        size: size, modificationDate: mtime, contentType: type, posixPermissions: mode,
                        owner: owner.isEmpty ? nil : owner, group: group.isEmpty ? nil : group, linkDestination: link)
    }

    /// POSIX shell single-quote escaping: the result is one word, whatever `s` contains.
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
