import Foundation
import PorpoiseCore
import PorpoiseTestSupport

/// Stands in for a command-line tool (curl, adb) that needs a server or a device we don't have: an executable script
/// that records the arguments and stdin of every call, prints a canned reply and exits with a canned status.
final class RecordingTool {
    struct Call {
        let args: [String]
        let stdin: String
    }

    let path: String
    private let scratch: Scratch

    init() throws {
        scratch = try Scratch("tool")
        let d = RemoteParsing.quote(scratch.url.path)
        let script = try scratch.file("tool", """
            #!/bin/sh
            d=\(d)
            n=$(cat "$d/count" 2>/dev/null || echo 0); echo $((n + 1)) > "$d/count"
            printf '%s\\0' "$@" > "$d/args-$n"
            cat > "$d/stdin-$n"
            if [ -f "$d/reply-$n" ]; then cat "$d/reply-$n"; else cat "$d/reply" 2>/dev/null; fi
            exit "$(cat "$d/status-$n" 2>/dev/null || cat "$d/status" 2>/dev/null || echo 0)"

            """)
        chmod(script.path, 0o755)
        path = script.path
    }

    /// What every call prints and how it exits, unless `call` (0-based) picks one call.
    func reply(_ output: String, status: Int32 = 0, call: Int? = nil) throws {
        let suffix = call.map { "-\($0)" } ?? ""
        try scratch.file("reply" + suffix, output)
        try scratch.file("status" + suffix, "\(status)")
    }

    var calls: [Call] {
        let count = Int(scratch.read("count")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        return (0..<count).map { n in
            let args = (try? Data(contentsOf: scratch.path("args-\(n)"))) ?? Data()
            return Call(args: args.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) },
                        stdin: scratch.read("stdin-\(n)") ?? "")
        }
    }
}
