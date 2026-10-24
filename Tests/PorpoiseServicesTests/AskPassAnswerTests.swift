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
