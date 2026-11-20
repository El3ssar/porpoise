import Foundation
import PorpoiseCore

/// Native password / confirmation prompt. ssh calls our own binary with `--askpass "<prompt>"`.
public enum AskPass {
    /// Automatic answer during an explicitly approved host-key change.
    public static func acceptedAnswer(prompt: String, fingerprint: String?) -> String? {
        guard let fingerprint, !fingerprint.isEmpty, isHostKeyConfirmation(prompt) else { return nil }
        return prompt.lowercased().contains("please type") ? "no" : fingerprint
    }

    /// The account and server an ssh password prompt asks for: "user@host's password:" (password login) or
    /// "(user@host) Password:" (keyboard-interactive). Key passphrases and one-time codes are never kept.
    public static func passwordLogin(_ prompt: String) -> (account: String, server: String)? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let login: Substring
        if text.hasSuffix("'s password:") {
            login = text.dropLast("'s password:".count)
        } else if text.hasPrefix("("), text.hasSuffix(") Password:") {
            login = text.dropFirst().dropLast(") Password:".count)
        } else {
            return nil
        }
        guard let at = login.lastIndex(of: "@") else { return nil }
        let account = String(login[..<at]), server = String(login[login.index(after: at)...])
        return account.isEmpty || server.isEmpty ? nil : (account, server)
    }

    /// The password saved for the prompt's login, offered only to the first prompt of an ssh process: when ssh asks
    /// again, the saved one was wrong, and the person types it. `attempts`: where the prompts already answered are noted.
    static func savedPassword(
        prompt: String, sshProcess: Int32, store: any PasswordCredentialStore,
        attempts: URL = FileManager.default.temporaryDirectory, now: Date = Date()
    ) -> String? {
        guard let login = passwordLogin(prompt) else { return nil }
        let marker = attempts.appendingPathComponent("porpoise-askpass-\(sshProcess)-\(login.account)@\(login.server)")
        // A note older than a login takes is another ssh's that had the same process ID.
        if let made = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
            now.timeIntervalSince(made) < 60
        {
            return nil
        }
        try? Data().write(to: marker)
        return store.password(server: login.server, account: login.account, scheme: "sftp")
    }

    /// Keeps the password typed into a prompt, for the next connection's first prompt.
    static func remember(_ password: String, prompt: String, store: any PasswordCredentialStore) {
        guard let login = passwordLogin(prompt), !password.isEmpty else { return }
        store.save(server: login.server, account: login.account, password: password, scheme: "sftp")
    }

    /// The Keychain (the memory store in test processes), as the prompt helper uses it.
    public static func savedPassword(prompt: String, sshProcess: Int32) -> String? {
        savedPassword(prompt: prompt, sshProcess: sshProcess, store: CredentialStores.passwords())
    }

    public static func remember(_ password: String, prompt: String) {
        remember(password, prompt: prompt, store: CredentialStores.passwords())
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
