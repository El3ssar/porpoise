import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite struct DiagnosticsTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date(timeIntervalSince1970: 1_700_000_000)
        func now() -> Date { lock.withLock { time } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time.addTimeInterval(seconds) } }
    }

    private let identity = DiagnosticIdentity(version: "0.9.1", build: "0.9.1")

    private func json(_ export: DiagnosticExport) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: export.data) as? [String: Any])
    }

    private func events(_ export: DiagnosticExport) throws -> [[String: Any]] {
        try #require(try json(export)["events"] as? [[String: Any]])
    }

    private func strings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let dictionary = value as? [String: Any] {
            return Array(dictionary.keys) + dictionary.values.flatMap { strings(in: $0) }
        }
        if let array = value as? [Any] { return array.flatMap { strings(in: $0) } }
        return []
    }

    @Test func privateErrorContextAndInvalidBuildMetadataNeverReachThePayload() throws {
        let secrets = [
            "/Users/alice/Finance/private-tax.pdf", "private-cloud-photo.jpg", "bearer-secret-123",
            "https://user:password@private-host.example/path?access_token=refresh-secret", "account@example.com",
        ]
        let hostile = secrets.joined(separator: " | ")
        let store = DiagnosticStore(identity: DiagnosticIdentity(version: hostile, build: hostile))
        for domain in [NSURLErrorDomain, NSCocoaErrorDomain, hostile] {
            let error = NSError(
                domain: domain, code: NSURLErrorCannotConnectToHost,
                userInfo: [
                    NSLocalizedDescriptionKey: hostile, NSFilePathErrorKey: secrets[0], NSURLErrorFailingURLStringErrorKey: secrets[3],
                    NSUnderlyingErrorKey: NSError(domain: hostile, code: 123, userInfo: [NSLocalizedDescriptionKey: hostile]),
                ])
            #expect(store.record(.providerDisconnected, error: error))
        }
        let preview = try store.preview()
        for secret in secrets { #expect(!preview.text.contains(secret)) }
        #expect(!preview.text.contains("access_token") && !preview.text.contains("private-host"))
        let payload = try json(preview)
        // Inspect decoded values too: raw-text checks alone can miss JSON-escaped slashes or control characters.
        let decodedStrings = strings(in: payload)
        for secret in secrets { #expect(!decodedStrings.contains { $0.contains(secret) }) }
        #expect(Set(payload.keys) == ["schemaVersion", "identity", "generatedAt", "events"])
        let build = try #require(payload["identity"] as? [String: Any])
        #expect(Set(build.keys) == ["version", "build", "osVersion", "architecture"])
        #expect(build["version"] as? String == "unknown" && build["build"] as? String == "unknown")
        for event in try events(preview) {
            #expect(Set(event.keys) == ["timestamp", "code", "failure", "correlation"])
        }
        #expect(try events(preview).map { $0["failure"] as? String } == ["network", "unknown", "unknown"])
    }

    @Test func eventCodesAndErrorCategoriesAreStableAndClosed() throws {
        let store = DiagnosticStore(identity: identity)
        let cases: [(NSError, DiagnosticFailure)] = [
            (NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError), .cancelled),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError), .permission),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError), .permission),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError), .notFound),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError), .notFound),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), .noSpace),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError), .conflict),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), .cancelled),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), .timeout),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired), .authentication),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorUserCancelledAuthentication), .authentication),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), .network),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable), .unavailable),
            (NSError(domain: NSURLErrorDomain, code: -99999), .unknown),
        ]
        for (error, expected) in cases { #expect(DiagnosticFailure(error: error) == expected) }
        for code in DiagnosticEvent.Code.allCases { #expect(store.record(code)) }
        #expect(
            try events(store.preview()).compactMap { $0["code"] as? String } == [
                "persistence.write_failed", "provider.connected", "provider.disconnected", "subprocess.exited", "helper.unavailable",
                "recovery.started", "recovery.finished",
            ])
        #expect(try json(store.preview())["schemaVersion"] as? Int == 1)
    }

    @Test func metadataCorrelationAndSelectedReviewArePreserved() throws {
        let store = DiagnosticStore(identity: identity)
        let operation = DiagnosticCorrelation()
        store.record(.recoveryStarted, correlation: operation)
        store.record(.providerConnected)
        store.record(.recoveryFinished, correlation: operation)
        let selected = try store.preview(correlations: [operation])
        let selectedEvents = try events(selected)
        #expect(selectedEvents.count == 2)
        #expect(selectedEvents[0]["correlation"] as? String == selectedEvents[1]["correlation"] as? String)
        let metadata = try #require(try json(selected)["identity"] as? [String: String])
        #expect(metadata["version"] == "0.9.1" && metadata["build"] == "0.9.1")
        #expect(metadata["architecture"] == identity.architecture && metadata["osVersion"] == identity.osVersion)
        #expect(try events(store.preview(correlations: [])).isEmpty)
        #expect(try events(store.preview()).count == 3)
    }

    @Test func countAndFullEncodedByteCapsRetainTheNewestEvents() throws {
        let byCount = DiagnosticStore(identity: identity, limits: .init(maximumEvents: 2))
        byCount.record(.recoveryStarted)
        byCount.record(.providerConnected)
        byCount.record(.recoveryFinished)
        #expect(try events(byCount.preview()).compactMap { $0["code"] as? String } == ["provider.connected", "recovery.finished"])
        let byBytes = DiagnosticStore(identity: identity, limits: .init(maximumEvents: 1000, maximumBytes: 1024))
        for _ in 0..<100 { byBytes.record(.providerConnected) }
        let last = DiagnosticCorrelation()
        byBytes.record(.recoveryFinished, correlation: last)
        let preview = try byBytes.preview()
        #expect(preview.data.count <= 1024)
        #expect(try events(preview).count < 100 && !events(preview).isEmpty)
        #expect(try events(byBytes.preview(correlations: [last])).count == 1)
    }

    @Test func ageExpiryClockRollbackDisabledAndClearDoNotLeakOldEvents() throws {
        let clock = Clock()
        let store = DiagnosticStore(identity: identity, limits: .init(maximumAge: 10), now: { clock.now() })
        store.record(.recoveryStarted)
        clock.advance(11)
        #expect(try events(store.preview()).isEmpty)
        store.record(.providerConnected)
        clock.advance(-1)
        #expect(try events(store.preview()).isEmpty)
        store.record(.recoveryFinished)
        store.clear()
        #expect(try events(store.preview()).isEmpty)
        let disabled = DiagnosticStore(identity: identity, limits: .init(maximumEvents: 0))
        #expect(!disabled.record(.helperUnavailable))
        #expect(try events(disabled.preview()).isEmpty)
    }

    @Test func limitAndVersionInputsFailClosed() {
        let low = DiagnosticStore.Limits(maximumEvents: -1, maximumBytes: -1, maximumAge: -.infinity)
        #expect(low.maximumEvents == 0 && low.maximumBytes == 1024 && low.maximumAge == 86400)
        let high = DiagnosticStore.Limits(maximumEvents: .max, maximumBytes: .max, maximumAge: 1e12)
        #expect(high.maximumEvents == 1000 && high.maximumBytes == 1024 * 1024 && high.maximumAge == 604800)
        #expect(DiagnosticStore.Limits(maximumAge: -1).maximumAge == 1)
        let invalidVersions: [String?] = [
            nil, "", "1..2", ".1", "1.", "1.2.3.4.5", "12345", "１.２", "token\n0.9.1", String(repeating: "9", count: 100),
        ]
        for raw in invalidVersions {
            #expect(DiagnosticIdentity(version: raw, build: raw).version == "unknown")
            #expect(DiagnosticIdentity(version: raw, build: raw).build == "unknown")
        }
    }

    @Test func concurrentRecordingIsBoundedAndProducesValidJSON() throws {
        let store = DiagnosticStore(identity: identity, limits: .init(maximumEvents: 30, maximumBytes: 8192))
        DispatchQueue.concurrentPerform(iterations: 200) { _ in store.record(.subprocessExited) }
        let preview = try store.preview()
        let rows = try events(preview)
        #expect(rows.count == 30 && preview.data.count <= 8192)
        #expect(Set(rows.compactMap { $0["correlation"] as? String }).count == 30)
    }

    @Test func reviewedExportWritesIdenticalBytesLocallyWithoutReplacingFiles() throws {
        let scratch = try Scratch("diagnostic-export")
        let store = DiagnosticStore(identity: identity)
        store.record(.providerConnected)
        let reviewed = try store.preview()
        store.record(.recoveryFinished)
        let target = scratch.path("reviewed.json")
        try reviewed.write(to: target)
        #expect(try Data(contentsOf: target) == reviewed.data)
        #expect(try events(reviewed).count == 1 && events(store.preview()).count == 2)
        #expect(throws: (any Error).self) { try store.preview().write(to: target) }
        #expect(try Data(contentsOf: target) == reviewed.data)
        for url in [URL(string: "https://user:password@example.com/log?token=secret")!, URL(string: "file://remote-host/private.json")!] {
            #expect(throws: DiagnosticExport.Failure.localFileRequired) { try reviewed.write(to: url) }
        }
        #expect(throws: (any Error).self) { try reviewed.write(to: scratch.path("missing/export.json")) }
    }

    @Test func invalidClockCannotBeEncodedOrRecorded() throws {
        let store = DiagnosticStore(identity: identity, limits: .init(), now: { Date(timeIntervalSince1970: .nan) })
        #expect(!store.record(.helperUnavailable))
        #expect(throws: DiagnosticExport.Failure.invalidClock) { try store.preview() }
    }
}
