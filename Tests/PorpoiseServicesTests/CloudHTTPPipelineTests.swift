import Foundation
import PorpoiseCore
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// One authorized request path and one pager for every cloud service: the token renewed once, a busy service waited
/// for (as long as it asks), a failed one tried again only when that can't do anything twice.
@Suite(.serialized, .isolatedSettings) struct CloudHTTPPipelineTests {
    /// Answers in turn (the last one again once they run out), counting what was asked.
    private final class Script: @unchecked Sendable {
        let lock = NSLock()
        var answers: [(Int, [String: String])]
        var requests: [URLRequest] = []
        var waits: [TimeInterval] = []
        init(_ answers: [(Int, [String: String])]) { self.answers = answers }
        var count: Int { lock.withLock { requests.count } }
        func answer(_ request: URLRequest) -> (Data, HTTPURLResponse) {
            lock.withLock {
                requests.append(request)
                let (status, headers) = answers.count > 1 ? answers.removeFirst() : answers[0]
                return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
            }
        }
    }
    private struct Busy: Error {}
    private struct Failed: Error {}

    private func client(_ script: Script, tokens: @escaping CloudAuthorizedClient.Token = { $0 == nil ? "first" : "renewed" })
        -> CloudAuthorizedClient
    {
        CloudAuthorizedClient(
            transport: CloudHTTPTransport { request in script.answer(request) }, token: tokens,
            classify: { _, response, idempotent in
                switch response.statusCode {
                case 200..<300: return .done
                case 429: return .retry(Busy())
                case 500...599: return idempotent ? .retry(Failed()) : .fail(Failed())
                default: return .fail(Failed())
                }
            }, wait: { delay in script.lock.withLock { script.waits.append(delay) } })
    }

    @Test func aBusyServiceIsWaitedForAsLongAsItAsks() async throws {
        let script = Script([(429, ["Retry-After": "3"]), (429, [:]), (200, [:])])
        _ = try await client(script).send(URLRequest(url: URL(string: "https://x.invalid/a")!), idempotent: false)
        #expect(script.count == 3)
        #expect(script.waits.count == 2 && (3...3.06).contains(script.waits[0]) && (2...2.06).contains(script.waits[1]))
        #expect(
            CloudAuthorizedClient.delay(
                HTTPURLResponse(url: URL(string: "https://x.invalid")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "600"])!,
                attempt: 0) == 30)
        #expect(CloudAuthorizedClient.delay(HTTPURLResponse(), attempt: 3) == 8)
    }

    @Test func aFailedRequestIsSentAgainOnlyWhenThatCantDoAnythingTwice() async throws {
        let read = Script([(503, [:]), (200, [:])])
        _ = try await client(read).send(URLRequest(url: URL(string: "https://x.invalid/a")!), idempotent: true)
        #expect(read.count == 2)
        let change = Script([(503, [:]), (200, [:])])
        await #expect(throws: Failed.self) { try await client(change).send(URLRequest(url: URL(string: "https://x.invalid/a")!), idempotent: false) }
        #expect(change.count == 1)
        let busy = Script([(429, ["Retry-After": "0"])])
        await #expect(throws: Busy.self) { try await client(busy).send(URLRequest(url: URL(string: "https://x.invalid/a")!), idempotent: true) }
        #expect(busy.count == 5)
    }

    @Test func aRefusedTokenIsRenewedOnce() async throws {
        let script = Script([(401, [:]), (200, [:])])
        let rejected = Script([(200, [:])])
        _ = try await client(script) { refused in
            if let refused { _ = rejected.answer(URLRequest(url: URL(string: "https://x.invalid/" + refused)!)) }
            return refused == nil ? "first" : "renewed"
        }.send(URLRequest(url: URL(string: "https://x.invalid/a")!), idempotent: true)
        #expect(script.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer first", "Bearer renewed"])
        #expect(rejected.requests.map { $0.url!.lastPathComponent } == ["first"])
        let again = Script([(401, [:])])
        await #expect(throws: Failed.self) { try await client(again).send(URLRequest(url: URL(string: "https://x.invalid/a")!), idempotent: true) }
        #expect(again.count == 2)
    }

    @Test func pagesAreReadUntilTheLastAndNeverRoundInCircles() async throws {
        var pages: [String?] = []
        try await CloudPager.each(repeated: Failed()) { (token: String?) in
            pages.append(token); return ["a", "b", nil][pages.count - 1]
        }
        #expect(pages == [nil, "a", "b"])
        var calls = 0
        await #expect(throws: Failed.self) {
            try await CloudPager.each(repeated: Failed()) { (_: String?) in
                calls += 1; return "same"
            }
        }
        #expect(calls == 2)
        let cancelled = Task {
            try await CloudPager.each(repeated: Failed()) { (_: String?) in
                withUnsafeCurrentTask { $0?.cancel() }; return UUID().uuidString
            }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    // Drive: reads honor Retry-After (they waited 1, 2, 4… s whatever Drive asked), downloads retry a failed server.
    @Test func driveReadsAndDownloadsFollowTheOnePolicy() async throws {
        let server = try FakeDriveServer(), scratch = try Scratch()
        let (_, tokens, _) = try server.client()
        let read = Script([(429, ["Retry-After": "0"]), (200, [:])])
        let reader = DriveClient(
            accountID: UUID(), tokens: tokens, http: .init { read.answer($0) }, baseURL: server.base,
            mutationJournal: .init(folder: scratch.url.appendingPathComponent("a")),
            retryWait: { delay in read.lock.withLock { read.waits.append(delay) } })
        _ = try await reader.request("about")
        // The pause was the 0 s asked for (plus jitter), not the 1 s of a backoff that ignored it.
        #expect(read.count == 2 && read.waits.count == 1 && (0...0.06).contains(read.waits[0]))
        let download = Script([(503, ["Retry-After": "0"]), (200, [:])])
        let downloader = DriveClient(
            accountID: UUID(), tokens: tokens, http: .init { download.answer($0) }, baseURL: server.base,
            mutationJournal: .init(folder: scratch.url.appendingPathComponent("b")))
        #expect(try await downloader.mutationResponse(server.base).1.statusCode == 200)
        #expect(download.count == 2)
        let change = Script([(503, ["Retry-After": "0"]), (200, [:])])
        let changer = DriveClient(
            accountID: UUID(), tokens: tokens, http: .init { change.answer($0) }, baseURL: server.base,
            mutationJournal: .init(folder: scratch.url.appendingPathComponent("c")))
        await #expect(throws: DriveError.http(503)) { try await changer.mutationResponse(server.base, method: "POST") }
        #expect(change.count == 1)
    }

    // Drive thumbnails renew an expired token (they gave up with "reconnect") and tell the account's state.
    @Test func driveThumbnailsRenewAnExpiredToken() async throws {
        let server = try FakeDriveServer(), scratch = try Scratch()
        let (_, tokens, _) = try server.client()
        let script = Script([(401, [:]), (200, [:])])
        let reports = Script([(200, [:])])
        let client = DriveClient(
            accountID: UUID(), tokens: tokens, http: .init { script.answer($0) }, baseURL: server.base,
            mutationJournal: .init(folder: scratch.url.appendingPathComponent("j")), metadataDirectory: scratch.url,
            report: { error in _ = reports.answer(URLRequest(url: URL(string: error == nil ? "https://ok.invalid" : "https://error.invalid")!)) })
        var file = DriveFile(id: "image-a", name: "photo.jpg", mimeType: "image/jpeg")
        file.thumbnailLink = server.base.appendingPathComponent("thumbnail/image-a")
        file.hasThumbnail = true
        _ = try await client.thumbnail(file)
        #expect(script.count == 2)
        #expect(script.requests.last?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        #expect(reports.requests.contains { $0.url?.host == "ok.invalid" })
    }

    // Dropbox: busy and failed reads are waited for and sent again (a 429 surfaced as "request failed (429)").
    @Test func dropboxWaitsForABusyServiceAndRetriesReadsOnly() async throws {
        let server = try FakeDropboxServer()
        let base = try server.client()
        let read = Script([(429, ["Retry-After": "0"]), (503, ["Retry-After": "0"]), (200, [:])])
        let reader = DropboxClient(
            accountID: base.accountID, configuration: server.config, tokens: base.tokens, directory: server.directory,
            http: CloudHTTPTransport { read.answer($0) })
        _ = try await reader.data("files/get_metadata", arguments: ["path": "id:hello"])
        #expect(read.count == 3)
        let change = Script([(503, ["Retry-After": "0"]), (200, [:])])
        let changer = DropboxClient(
            accountID: base.accountID, configuration: server.config, tokens: base.tokens, directory: server.directory,
            http: CloudHTTPTransport { change.answer($0) })
        await #expect(throws: DropboxError.self) { try await changer.data("files/create_folder_v2", arguments: ["path": "/x"]) }
        #expect(change.count == 1)
        let busy = Script([(429, ["Retry-After": "0"]), (200, [:])])
        let creator = DropboxClient(
            accountID: base.accountID, configuration: server.config, tokens: base.tokens, directory: server.directory,
            http: CloudHTTPTransport { busy.answer($0) })
        _ = try await creator.data("files/create_folder_v2", arguments: ["path": "/x"])
        #expect(busy.count == 2)  // a 429 means nothing was done: safe for a change too
        #expect(DropboxClient.reads("files/list_folder/continue") && !DropboxClient.reads("files/delete_v2"))
    }
}
