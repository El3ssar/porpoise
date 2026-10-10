import Foundation
import PorpoiseCore

/// Native password / confirmation prompt. ssh calls our own binary with `--askpass "<prompt>"`.
public enum AskPass {
    /// Path of a tiny script ssh can execute as SSH_ASKPASS (it calls back into the app binary).
    static let scriptPath: String = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Porpoise")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("askpass.sh")
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        // Single-quoted, so an install path with quotes, `$` or backticks stays a plain path.
        let body = "#!/bin/sh\nexec \(RemoteParsing.quote(exe)) --askpass \"$1\"\n"
        try? body.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o700)
        return script.path
    }()
}
