import Foundation
import Testing

@testable import PorpoiseServices

@Suite struct AskPassAnswerTests {
    @Test func acceptedFingerprintsOnlyAnswerHostKeyQuestions() {
        let fingerprint = "SHA256:accepted"
        #expect(
            AskPass.acceptedAnswer(prompt: "Are you sure you want to continue connecting (yes/no/[fingerprint])?", fingerprint: fingerprint)
                == fingerprint)
        #expect(AskPass.acceptedAnswer(prompt: "Please type 'yes', 'no' or the fingerprint:", fingerprint: fingerprint) == "no")
        #expect(AskPass.acceptedAnswer(prompt: "user@host's password:", fingerprint: fingerprint) == nil)
        #expect(AskPass.acceptedAnswer(prompt: "Please type your password:", fingerprint: fingerprint) == nil)
        #expect(AskPass.acceptedAnswer(prompt: "Continue connecting (yes/no)?", fingerprint: nil) == nil)
        #expect(AskPass.acceptedAnswer(prompt: "Continue connecting (yes/no)?", fingerprint: "") == nil)
        #expect(AskPass.acceptedAnswer(prompt: "Enter passphrase for key '/scratch/key':", fingerprint: fingerprint) == nil)
    }
}

/// Issue #26: an SFTP password typed with "Remember" answers the next connection's first prompt.
@Suite struct AskPassSavedPasswordTests {
    @Test func onlyPasswordPromptsNameALogin() {
        #expect(AskPass.passwordLogin("u0_a238@motorola-edge-50-fusion.lan's password: ")! == ("u0_a238", "motorola-edge-50-fusion.lan"))
        #expect(AskPass.passwordLogin("(me@host.example) Password:")! == ("me", "host.example"))
        #expect(AskPass.passwordLogin("Enter passphrase for key '/Users/me/.ssh/id_ed25519':") == nil)
        #expect(AskPass.passwordLogin("Verification code:") == nil)
        #expect(AskPass.passwordLogin("Are you sure you want to continue connecting (yes/no/[fingerprint])?") == nil)
        #expect(AskPass.passwordLogin("@host's password:") == nil)
    }

    @Test func aSavedPasswordAnswersOnlyTheFirstPromptOfAnSSHProcess() throws {
        let attempts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: attempts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: attempts) }
        let store = MemoryCredentials(), prompt = "me@nas.local's password:"
        #expect(AskPass.savedPassword(prompt: prompt, sshProcess: 10, store: store, attempts: attempts) == nil)
        AskPass.remember("secret", prompt: prompt, store: store)
        #expect(store.password(server: "nas.local", account: "me", scheme: "sftp") == "secret")
        #expect(store.password(server: "nas.local", account: "me", scheme: "ftp") == nil)
        #expect(AskPass.savedPassword(prompt: prompt, sshProcess: 11, store: store, attempts: attempts) == "secret")
        // Asked again by the same ssh: the saved password was refused, so the person is asked.
        #expect(AskPass.savedPassword(prompt: prompt, sshProcess: 11, store: store, attempts: attempts) == nil)
        // A later ssh that got the same process ID gets it again.
        #expect(AskPass.savedPassword(prompt: prompt, sshProcess: 11, store: store, attempts: attempts, now: Date() + 120) == "secret")
        // Passphrases and codes are never kept.
        AskPass.remember("code", prompt: "Verification code:", store: store)
        #expect(AskPass.savedPassword(prompt: "Verification code:", sshProcess: 12, store: store, attempts: attempts) == nil)
    }
}
