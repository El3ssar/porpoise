import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite struct SSHPublicationReplyTests {
    @Test func publicationIsNotRetriedAfterALostReply() throws {
        let scratch = try Scratch()
        let log = scratch.path("attempts")
        let fake = try scratch.file(
            "ssh",
            """
            #!/bin/sh
            for arg do last="$arg"; done
            case "$last" in
              *"mv -f"*)
                echo attempt >> '\(log.path)'
                /bin/sh -c "$last" || exit $?
                echo 'Connection reset by peer' >&2
                exit 255;;
            esac
            exit 0

            """)
        chmod(fake.path, 0o700)
        let provider = SSHProvider(
            url: URL(string: "sftp://fake.invalid/")!,
            isolation: .init(options: [], controlDir: scratch.url, executable: fake.path))
        provider.wait = { _ in }
        try provider.exec("true")  // establish prior successful connection, enabling the reconnect policy
        let staged = try scratch.file("staged", "new")
        let target = try scratch.file("target", "old")
        #expect(throws: TransferConnectionError.self) { try provider.publishTransferFile(staged, to: target, modified: nil) }
        #expect(scratch.read("target") == "new")
        #expect(scratch.read("attempts") == "attempt\n")
    }
}
