import Foundation

/// Seeded random input for parsers and quoting: pieces of the syntax they read (separators, permissions, dates, numbers
/// at the edges of Int64, quotes, Unicode), joined at random or spliced into valid lines. Same inputs on every run.
public struct Fuzzer {
    public var rng: SeededGenerator

    public init(seed: UInt64) { rng = SeededGenerator(seed: seed) }

    public static let atoms: [String] = [
        "\t", "\n", "\r", "\r\n", "\0", " ", "  ", "-", "/", ".", "..", ":", ",", "->", " -> ", "./", "~",
        "d", "l", "r", "w", "x", "s", "S", "t", "T", "c", "b", "p",
        "-rwxr-xr-x", "drwxr-xr-x", "lrwxrwxrwx", "crw-rw-rw-", "-rwsr-sr-t", "dl", "fd", "ff", "lf",
        "0", "1", "7", "9", "42", "-1", "1,", "1, 3", "644", "0755", "99999999999999999999", "9223372036854775807",
        "-9223372036854775808", "1700000000.5", "nan", "inf", "1e400",
        "Jan", "Feb", "Dec", "Foo", "2024-01-05", "12:00", "24:61", "2023", "31", "00:34:40.56",
        "%", "%2e", "%2f", "%00", "%ZZ", "\\", "'", "\"", "`", "$(", ")", "[", "]", "!", "*", "?", "^", "{", "}", "|", "+",
        "é", "e\u{301}", "\u{301}", "\u{FE0F}", "🐬", "\u{202E}", "\u{FEFF}", "\u{200B}", "한",
        "v", "beta", "Regular File", "Directory", "Symbolic Link", "Character Device", "me", "staff", "root",
        "device", "offline", "model:Pixel_7", "usb:1-1", "List of devices attached",
        "[Color1]", "[Color7Intense]", "[Color9]", "[Color8Intense]", "[Background]", "[Foreground]", "Color=1,2,3",
        "Color=-5,999,x", "Color=", "Input #0, ", "matroska,webm", "Duration: ", "Stream #0:0: Video: h264", "Audio: aac",
        "attached pic", "S3CRET", "secret.txt", "index.m3u8", "sftp://", "user@host:", "ssh://", "fish://", "@",
    ]

    public mutating func int(_ n: Int) -> Int { Int.random(in: 0..<n, using: &rng) }
    public mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }

    /// Up to `max` atoms, now and then a random scalar.
    public mutating func string(max: Int = 24) -> String {
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

    /// `s` with a few random edits by code point (so a mark can land right after a quote or a slash): delete a run,
    /// insert atoms, duplicate a run.
    public mutating func mutate(_ s: String) -> String {
        var c = Array(s.unicodeScalars)
        for _ in 0..<(1 + int(3)) {
            let i = c.isEmpty ? 0 : int(c.count + 1)
            switch int(3) {
            case 0 where !c.isEmpty:
                let a = min(i, c.count - 1)
                c.removeSubrange(a..<min(c.count, a + 1 + int(4)))
            case 1:
                c.insert(contentsOf: Array(string(max: 2).unicodeScalars), at: min(i, c.count))
            default:
                guard !c.isEmpty else { continue }
                let a = min(i, c.count - 1)
                c.insert(contentsOf: c[a..<min(c.count, a + 1 + int(6))], at: a)
            }
        }
        return String(String.UnicodeScalarView(c))
    }

    /// Random or mutated-from-a-sample text, `lines` records joined by `separator`.
    public mutating func text(samples: [String], lines: Int = 6, separator: String = "\n") -> String {
        (0..<(1 + int(lines))).map { _ in int(3) == 0 ? string() : mutate(pick(samples)) }.joined(separator: separator)
    }
}

/// Collects invariant violations so a failure reports a few examples instead of thousands of expectations.
public struct Violations {
    public private(set) var list: [String] = []
    public init() {}
    public mutating func check(_ ok: Bool, _ what: @autoclosure () -> String) { if !ok && list.count < 5 { list.append(what()) } }
}

/// Waits up to `timeout` seconds for `condition`, polling; returns whether it came true.
public func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}
