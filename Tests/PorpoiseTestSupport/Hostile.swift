import Foundation

/// File names that break naive code: line breaks, control characters, shell and AppleScript syntax, look-alike
/// Unicode, URL-like prefixes and names at the 255-byte limit. Every one is a valid macOS file name.
/// Strings that would run something if a shell ever evaluated them only `echo`, so a slip shows up as wrong output.
public enum HostileNames {
    /// 255 bytes of UTF-8. (APFS counts its 255 limit in UTF-16 units of the decomposed name that Foundation
    /// writes, so the "é" one is longer on disk and has no room for " copy" either.)
    public static let long255Ascii = String(repeating: "n", count: 255)
    public static let long255TwoByte = String(repeating: "\u{E9}", count: 127) + "x"        // é (NFC) × 127 + 1
    public static let long255Emoji = String(repeating: "\u{1F42C}", count: 63) + "abc"      // 🐬 × 63 + 3

    public static let all: [String] = [
        "new\nline", "trailing newline\n", "\nleading newline", "carriage\rreturn", "crlf\r\nname", "tab\there",
        "trailing cr\r", "trailing crlf\r\n", "\r",
        "bell\u{07}esc\u{1B}[31mred", "del\u{7F}x", "\u{01}\u{02}\u{1F}",
        "-rf", "--help", "-", "-n", "-e", " leading space", "trailing space ", "  ",
        "'single'", "\"double\"", "it's", "'", "\"", "`echo PWNED`", "$(echo PWNED)", "${HOME}", "$HOME", "$1", "bang!$",
        "a;b|c&d>e<f", "*?[ab]{c,d}~", "back\\slash", "\\", "\\n", "\\\"", "%s%n%d", "%2e%2e", "%00",
        "\u{201C}curly\u{201D} \u{2018}quotes\u{2019}", "\u{1F42C} emoji \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
        "\u{202E}gnp.exe", "zero\u{200B}width", "nbsp\u{00A0}space", "\u{FEFF}bom",
        "concat:x.mkv", "file:x", "http:", "a:b", "C:\\x", "#frag?q=1&x", "~", "~root",
        "...", ".hidden", "..x", "x.", ".tar.gz", "a.tar.gz",
        "\u{D55C}\u{AE00}", "\u{0627}\u{0644}\u{0639}\u{0631}\u{0628}\u{064A}\u{0629}",
        long255Ascii, long255TwoByte, long255Emoji,
    ]

    /// "é" written two ways: canonically equal Swift strings, different bytes on disk.
    public static let nfc = "caf\u{E9}"
    public static let nfd = "cafe\u{301}"
}

/// Bytes of a string: Swift's `==` treats NFC and NFD as equal, file systems don't.
public func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

/// Output of a tool run to completion.
public struct RunResult { public var status: Int32; public var out: Data; public var err: Data }

/// Runs a tool with arguments (no shell in between) and waits; stdout and stderr are drained concurrently.
@discardableResult
public func runTool(_ tool: String, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil) throws -> RunResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    if let env { p.environment = env }
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    p.waitUntilExit()
    return RunResult(status: p.terminationStatus, out: outData, err: errData)
}

/// SplitMix64: a small seeded generator, so "random" inputs are the same on every run.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
