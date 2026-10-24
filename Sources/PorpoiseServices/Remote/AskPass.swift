import Foundation
import PorpoiseCore

/// Native password / confirmation prompt. ssh calls our own binary with `--askpass "<prompt>"`.
public enum AskPass {
    /// Automatic answer during an explicitly approved host-key change.
    public static func acceptedAnswer(prompt: String, fingerprint: String?) -> String? {
        guard let fingerprint, !fingerprint.isEmpty, isHostKeyConfirmation(prompt) else { return nil }
        return prompt.lowercased().contains("please type") ? "no" : fingerprint
    }

    public static func isHostKeyConfirmation(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return lower.contains("yes/no") || lower.contains("continue connecting")
            || (lower.contains("please type") && lower.contains("fingerprint"))
    }

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
