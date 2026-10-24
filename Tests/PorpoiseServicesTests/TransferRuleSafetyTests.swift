import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

struct TransferRuleSafetyTests {
    @Test(arguments: ["published", "unchanged", "different"])
    func replacementReconcilesLostReplyOnlyWhenStageIsGoneAndBytesMatch(_ outcome: String) throws {
        let scratch = try Scratch(), server = try Scratch()
        let source = try scratch.file("source", "incoming")
        try server.file("destination/source", "previous")
        let remote = URL(string: "sftp://\(UUID().uuidString)/destination")!
        let provider = RuleProvider(root: server.url)
        provider.replacementOutcome = outcome
        RemoteFS.use(provider, for: remote)
        defer { RemoteFS.use(nil, for: remote) }
        let job = RemoteTransferJob(
            kind: .copy, sources: [source], destination: remote,
            control: JobControl(policy: .init(retries: 2, backoff: 0.01)), rule: .replace, options: .init())
        job.run()
        #expect(provider.publications == 1)
        #expect(job.errors.isEmpty == (outcome == "published"))
        #expect(job.results.count == (outcome == "published" ? 1 : 0))
        #expect(scratch.read("source") == "incoming")
        if outcome == "unchanged" { #expect(server.read("destination/source") == "previous") }
    }

    @Test(arguments: [false, true])
    func partialStagingCanRetryButUncertainPublicationCannot(_ failPublication: Bool) throws {
        let scratch = try Scratch(), server = try Scratch()
        let source = try scratch.file("source", "complete incoming bytes")
        let folder = try server.folder("destination")
        let remote = URL(string: "sftp://\(UUID().uuidString)/destination")!
        let provider = RuleProvider(root: server.url)
        provider.failUpload = !failPublication
        provider.failPublication = failPublication
        RemoteFS.use(provider, for: remote)
        defer { RemoteFS.use(nil, for: remote) }
        let control = JobControl(policy: .init(retries: 2, backoff: 0.01))
        let job = RemoteTransferJob(kind: .copy, sources: [source], destination: remote, control: control, rule: .ask, options: .init())
        job.run()
        #expect(provider.uploads == (failPublication ? 1 : 2))
        #expect(provider.publications == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("partial").path))
        #expect(server.read("destination/source") == "complete incoming bytes")
        #expect(scratch.read("source") == "complete incoming bytes")
        #expect(job.errors.isEmpty == !failPublication)
        #expect(control.transferNotes.isEmpty == failPublication)
    }

    @Test func retryUsesFreshOwnedDownloadSpace() throws {
        let scratch = try Scratch(), server = try Scratch()
        try server.file("source", "complete remote bytes")
        let remote = URL(string: "sftp://\(UUID().uuidString)/source")!
        let provider = RuleProvider(root: server.url)
        provider.failDownload = true
        RemoteFS.use(provider, for: remote)
        defer { RemoteFS.use(nil, for: remote) }
        let job = RemoteTransferJob(
            kind: .copy, sources: [remote], destination: scratch.url,
            control: JobControl(policy: .init(retries: 1, backoff: 0.01)), rule: .ask, options: .init())
        job.run()
        #expect(provider.downloadFolders.count == 2 && Set(provider.downloadFolders).count == 2)
        #expect(job.errors.isEmpty && scratch.read("source") == "complete remote bytes")
    }

    @Test func aFailedToolKeepsItsDiagnosticWhenItClosesStdinEarly() throws {
        let scratch = try Scratch()
        let input = try scratch.file("input", String(repeating: "x", count: 1_000_000))
        let control = JobControl().asTransferControl(onBytes: { _ in }, onStatus: { _ in })
        let result = try Shell.withTransferControl(control) {
            try Shell.run("/bin/sh", ["-c", "echo 'Permission denied' >&2; exit 7"], stdinFile: input, timeout: 30)
        }
        #expect(result.status == 7 && result.err.contains("Permission denied"))
    }
}

private final class RuleProvider: RemoteProvider, RemoteTransferTargetChecking, RemoteTransferPublishing {
    let base: CountingTransferProvider
    var failUpload = false, failDownload = false, failPublication = false
    var replacementOutcome = "published"
    var uploads = 0, publications = 0
    var downloadFolders: [URL] = []
    init(root: URL) { base = CountingTransferProvider(root: root) }
    func list(_ url: URL) throws -> [FileItem] { try base.list(url) }
    func download(_ url: URL, into folder: URL) throws -> URL {
        downloadFolders.append(folder)
        if failDownload && downloadFolders.count == 1 {
            try Data("partial".utf8).write(to: folder.appendingPathComponent(url.lastPathComponent))
            throw URLError(.networkConnectionLost)
        }
        return try base.download(url, into: folder)
    }
    func upload(_ url: URL, into folder: URL) throws {
        uploads += 1
        try base.upload(url, into: folder)
        if failUpload && uploads == 1 { throw URLError(.networkConnectionLost) }
    }
    func delete(_ urls: [URL]) throws { try base.delete(urls) }
    func makeFolder(_ url: URL) throws { try base.makeFolder(url) }
    func removeEmptyFolder(_ url: URL) throws { try base.removeEmptyFolder(url) }
    func rename(_ url: URL, to name: String) throws { try base.rename(url, to: name) }
    func move(_ urls: [URL], into folder: URL) throws {
        publications += 1
        try base.move(urls, into: folder)
        if failPublication { throw URLError(.networkConnectionLost) }
    }
    func copy(_ urls: [URL], into folder: URL) throws { try base.copy(urls, into: folder) }
    func publishTransferFile(_ staged: URL, to target: URL, modified: Date?) throws {
        publications += 1
        if replacementOutcome != "unchanged" {
            try FileManager.default.removeItem(at: base.local(target))
            try FileManager.default.moveItem(at: base.local(staged), to: base.local(target))
            if replacementOutcome == "different" { try Data("other writer".utf8).write(to: base.local(target)) }
        }
        throw TransferConnectionError(message: "Reply lost")
    }
    func rootTitle(_ url: URL) -> String { "Scratch transfer server" }
    func transferTargetExists(_ url: URL) throws -> Bool { try base.transferTargetExists(url) }
}
