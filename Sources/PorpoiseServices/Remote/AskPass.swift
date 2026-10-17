import Foundation
import PorpoiseCore

/// Native password / confirmation prompt. ssh calls our own binary with `--askpass "<prompt>"`.
public enum AskPass {
    /// Path of a tiny script ssh can execute as SSH_ASKPASS (it calls back into the app binary).
    static let scriptPath: String = writeScript(in: Settings.supportFolder)

    /// Writes the script into `dir` for the executable `exe` (tests pass a scratch folder); returns its path.
    static func writeScript(in dir: URL, exe: String = Bundle.main.executablePath ?? CommandLine.arguments[0]) -> String {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("askpass.sh")
        // Single-quoted, so an install path with quotes, `$` or backticks stays a plain path.
        let body = "#!/bin/sh\nexec \(RemoteParsing.quote(exe)) --askpass \"$1\"\n"
        try? body.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o700)
        return script.path
    }
}
