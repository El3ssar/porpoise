import Foundation
import PorpoiseCore
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

extension DriveMutationTests {
    @Test func quotaNoticeIsCancellableAndOfflineHasCalmStatus() async throws {
        let server = try server(), scratch = try Scratch()
        let (_, tokens, _) = try server.client()
        let status = MutationStatus()
        let throttled = DriveClient(
            accountID: UUID(), tokens: tokens,
            http: .init { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "10"])!)
            }, baseURL: server.base, mutationJournal: .init(folder: scratch.url))
        let context = DriveTransferContext(status: { status.record($0) })
        let task = Task { try await throttled.mutationResponse(server.base, context: context) }
        for _ in 0..<100 where status.values.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(status.values.contains("Slowed down by Google, retrying"))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let offline = DriveClient(
            accountID: UUID(), tokens: tokens, http: .init { _ in throw URLError(.notConnectedToInternet) }, baseURL: server.base)
        await #expect(throws: URLError.self) { try await offline.mutationResponse(server.base, context: context) }
        #expect(status.values.contains("Waiting for network"))
    }

    @Test func exhaustedThrottleAuthRefreshAndProviderReasonsStayDistinct() async throws {
        let server = try server()
        let (_, tokens, _) = try server.client()
        let count = MutationStatus()
        let throttled = DriveClient(
            accountID: UUID(), tokens: tokens,
            http: .init { request in
                count.record("attempt")
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "0"])!)
            }, baseURL: server.base)
        await #expect(throws: DriveError.quota) { try await throttled.mutationResponse(server.base) }
        #expect(count.values.count == 5)
        for (reason, error) in [
            ("insufficientPermissions", DriveError.needsWriteAccess), ("storageQuotaExceeded", .quota), ("exportSizeLimitExceeded", .exportTooLarge),
        ] {
            let client = DriveClient(
                accountID: UUID(), tokens: tokens,
                http: .init { request in
                    (
                        Data("{\"error\":\"\(reason)\"}".utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
                    )
                }, baseURL: server.base)
            await #expect(throws: error) { try await client.mutationResponse(server.base) }
        }
        let requests = MutationStatus()
        let refresh = DriveClient(
            accountID: UUID(), tokens: tokens,
            http: .init { request in
                requests.record("request")
                return (
                    Data(),
                    HTTPURLResponse(url: request.url!, statusCode: requests.values.count == 1 ? 401 : 200, httpVersion: nil, headerFields: nil)!
                )
            }, baseURL: server.base)
        #expect(try await refresh.mutationResponse(server.base).1.statusCode == 200)
        #expect(requests.values.count == 2)
    }

    @Test func hostileUploadSessionAndUnverifiedDownloadRangeAreRejected() async throws {
        let server = try server(), scratch = try Scratch()
        let (_, tokens, _) = try server.client()
        let source = scratch.url.appendingPathComponent("source.bin")
        try Data("bytes".utf8).write(to: source)
        let hostile = DriveHTTP { request in
            if request.url?.path.hasPrefix("/upload/") == true {
                return (
                    Data("{}".utf8),
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Location": "https://attacker.invalid/upload"])!
                )
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let client = DriveClient(
            accountID: UUID(), tokens: tokens, http: hostile, baseURL: server.base.appendingPathComponent("drive/v3/"),
            mutationJournal: .init(folder: scratch.url.appendingPathComponent("journal")))
        await #expect(throws: DriveMutationError.invalidSession) { try await client.upload(source, parentID: "root") }
        let range = DriveHTTP { request in
            if request.url?.query?.contains("alt=media") == true {
                return (Data("wrong bytes".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let download = DriveClient(
            accountID: UUID(), tokens: tokens, http: range, baseURL: server.base.appendingPathComponent("drive/v3/"),
            mutationJournal: .init(folder: scratch.url.appendingPathComponent("download")))
        await #expect(throws: DriveError.invalidResponse) { try await download.downloadToStaging(download.file("binary-a")) }
        #expect(try Data(contentsOf: source) == Data("bytes".utf8))
    }
}

private final class MutationStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var values: [String] { lock.withLock { entries } }
    func record(_ value: String?) { if let value { lock.withLock { entries.append(value) } } }
}

extension DriveMutationTests {
    @Test func sharedResourceKeysSurviveFreshCapabilityChecksAndMutations() async throws {
        let server = try server(), scratch = try Scratch()
        let (_, tokens, _) = try server.client()
        let captured = MutationStatus()
        let http = DriveHTTP { request in
            if let key = request.value(forHTTPHeaderField: "X-Goog-Drive-Resource-Keys") { captured.record(key) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let client = DriveClient(
            accountID: UUID(), tokens: tokens, http: http, baseURL: server.base.appendingPathComponent("drive/v3/"),
            mutationJournal: .init(folder: scratch.url.appendingPathComponent("journal")))
        _ = try await client.file("binary-a", resourceKey: "source-key")
        _ = try await client.file("folder-a", resourceKey: "parent-key")
        _ = try await client.copy("binary-a", to: "folder-a")
        #expect(captured.values.contains("binary-a/source-key,folder-a/parent-key"))
        #expect(captured.values.filter { $0 == "binary-a/source-key" }.count >= 2)
        let local = try scratch.file("shared-upload.txt", "shared folder bytes")
        _ = try await client.upload(local, parentID: "folder-a")
        #expect(captured.values.filter { $0 == "folder-a/parent-key" }.count >= 3)
    }
}
