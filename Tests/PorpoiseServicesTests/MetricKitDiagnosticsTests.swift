import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

@Suite struct MetricKitDiagnosticsTests {
    private let uuid = "E381A4A0-08CF-3A08-986A-5900F0581C62"
    private let privateText = "/Users/private-person/Secrets/token=private-token account@example.com"

    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    @Test func projectsOnlyReviewedValuesIntoExistingExportAndPreservesReviewedBytes() throws {
        let frame: [String: Any] = [
            "binaryUUID": uuid, "offsetIntoBinaryTextSegment": 1234, "sampleCount": 5,
            "binaryName": privateText, "symbol": privateText, "path": privateText,
        ]
        let stack = try data(["callStackTree": ["callStacks": [["callStackRootFrames": [frame]]]], "metadata": privateText])
        let begin = Date(timeIntervalSince1970: 1_700_000_000), end = begin.addingTimeInterval(1)
        let crash = MetricDiagnostic(
            kind: .crash, applicationVersion: privateText, signal: 11, exceptionType: 1,
            exceptionCode: 2, stackJSON: stack, windowBeginning: begin, windowEnding: end)
        let store = DiagnosticStore()
        #expect(store.record(crash))
        let reviewed = try store.preview()
        #expect(!reviewed.text.contains("private-person") && !reviewed.text.contains("private-token"))
        #expect(!reviewed.text.contains("account@example.com") && !reviewed.text.contains("binaryName"))
        let root = try #require(try JSONSerialization.jsonObject(with: reviewed.data) as? [String: Any])
        let event = try #require((root["events"] as? [[String: Any]])?.first)
        #expect(root["schemaVersion"] as? Int == 3 && event["code"] as? String == "app.crash")
        let diagnostic = try #require(event["diagnostic"] as? [String: Any])
        #expect(diagnostic["applicationVersion"] as? String == "unknown")
        #expect(diagnostic["windowBeginning"] as? Double == begin.timeIntervalSince1970 * 1000)
        #expect(crash.frames.count == 1 && crash.frames[0].textOffset == 1234 && crash.frames[0].samples == 5)
        #expect(crash.frames[0].binaryUUID.uuidString == uuid)
        #expect(store.record(MetricDiagnostic(kind: .hang, applicationVersion: "0.11.0", durationSeconds: 2.5)))
        let scratch = try Scratch()
        let file = scratch.path("review.json")
        try reviewed.write(to: file)
        #expect(try Data(contentsOf: file) == reviewed.data)
        #expect(try store.preview().data != reviewed.data)
    }

    @Test func malformedUnsafeAndOversizedFramesCannotIntroduceStringsOrUnboundedData() throws {
        let bad: [[String: Any]] = [
            ["binaryUUID": privateText, "offsetIntoBinaryTextSegment": 1],
            ["binaryUUID": uuid, "offsetIntoBinaryTextSegment": -1],
            ["binaryUUID": uuid, "offsetIntoBinaryTextSegment": true],
            ["binaryUUID": uuid, "offsetIntoBinaryTextSegment": 1.5],
            ["binaryUUID": uuid, "offsetIntoBinaryTextSegment": privateText],
        ]
        #expect(
            MetricDiagnostic(kind: .crash, applicationVersion: "1", stackJSON: try data(["callStacks": [["callStackRootFrames": bad]]])).frames
                .isEmpty)
        for bytes in [Data("invalid".utf8), Data(repeating: 32, count: 2 * 1024 * 1024 + 1)] {
            #expect(MetricDiagnostic(kind: .crash, applicationVersion: "1", stackJSON: bytes).frames.isEmpty)
        }
        let frame: [String: Any] = ["binaryUUID": uuid, "offsetIntoBinaryTextSegment": 10, "sampleCount": 1e20]
        let many = try data(["callStacks": [["callStackRootFrames": Array(repeating: frame, count: 1000)]]])
        let projected = MetricDiagnostic(kind: .hang, applicationVersion: "1", durationSeconds: .infinity, stackJSON: many)
        #expect(projected.frames.count == 64 && projected.frames.allSatisfy { $0.samples == 1_000_000 })
        #expect(projected.durationMilliseconds == nil)
        #expect(MetricDiagnostic(kind: .hang, applicationVersion: "1", durationSeconds: -1).durationMilliseconds == nil)
        #expect(MetricDiagnostic(kind: .hang, applicationVersion: "1", durationSeconds: 1e20).durationMilliseconds == 604_800_000)
        let invalid = MetricDiagnostic(
            kind: .crash, applicationVersion: "1", signal: -1, exceptionType: 1000,
            windowBeginning: Date(timeIntervalSince1970: .nan), windowEnding: Date())
        #expect(invalid.signal == nil && invalid.exceptionType == nil && invalid.windowBeginning == nil)
    }

    @Test func countBytesAndConcurrentCachedDeliveryAreBoundedAndDeduplicated() async throws {
        let store = DiagnosticStore(limits: .init(maximumEvents: 4, maximumBytes: 2048))
        let recorder = MetricDiagnosticRecorder(store: store)
        let begin = Date(timeIntervalSince1970: 1_700_000_000), end = begin.addingTimeInterval(10)
        let report = MetricDiagnostic(kind: .hang, applicationVersion: "0.11.0", durationSeconds: 3)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 { group.addTask { _ = recorder.receive(report, beginning: begin, ending: end) } }
        }
        func count() throws -> Int {
            let json = try #require(try JSONSerialization.jsonObject(with: store.preview().data) as? [String: Any])
            return try #require(json["events"] as? [Any]).count
        }
        #expect(try count() == 1)
        #expect(recorder.receive(report, beginning: begin, ending: end, occurrence: 1))
        #expect(try count() == 2)  // two real occurrences, cached replay of either does not duplicate them
        #expect(!recorder.receive(report, beginning: begin, ending: end, occurrence: 64))
        #expect(!recorder.receive(report, beginning: end, ending: begin))
        for i in 1...300 { _ = recorder.receive(report, beginning: begin, ending: end.addingTimeInterval(Double(i))) }
        #expect(try count() <= 4 && store.preview().data.count <= 2048)
        let disabled = MetricDiagnosticRecorder(store: DiagnosticStore(limits: .init(maximumEvents: 0)))
        #expect(!disabled.receive(report, beginning: begin, ending: end))
    }
}
