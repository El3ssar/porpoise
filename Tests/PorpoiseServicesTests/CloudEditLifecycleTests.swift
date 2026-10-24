import Foundation
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// The editing copy's life without a provider: an editor that replaces the file slowly, and opens that overlap.
@Suite struct CloudEditLifecycleTests {
    private struct File: Codable, Sendable { var id: String; var revision: String }
    private enum Failure: Error { case unavailable }
    /// Preparation waits until the test lets it finish, so two opens overlap however fast the machine.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        private(set) var prepared = 0
        func release() { lock.withLock { open = true } }
        func enter() { lock.withLock { prepared += 1 } }
        var isOpen: Bool { lock.withLock { open } }
        var count: Int { lock.withLock { prepared } }
    }
    private struct Engine: CloudEditEngine {
        let directory: URL
        let gate: Gate
        var unavailable: Error { Failure.unavailable }
        var sourceChanged: Error { Failure.unavailable }
        func checkConnection() throws {}
        func canUseCached(after error: Error) -> Bool { false }
        func identity(_ file: File) -> String { file.id }
        func revision(_ file: File) -> String? { file.revision }
        func hash(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }
        func uploadSource(_ operation: UUID) -> URL? { nil }
        func prepare(_ file: File, id: UUID, directory: URL, context: CloudTransferContext) async throws -> (File, URL) {
            gate.enter()
            while !gate.isOpen {
                try await context.checkpoint()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let url = directory.appendingPathComponent(id.uuidString + ".txt")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("initial".utf8).write(to: url)
            return (file, url)
        }
        func validate(_ file: File) async throws {}
        func publish(_ local: URL, file: File, operation: UUID, copyPath: String?, context: CloudTransferContext) async throws -> File { file }
        func prepareReplacement(_ file: File) async throws -> File { file }
        func conflict(_ error: Error) -> Bool { false }
        func remoteCopy(_ file: File, beside: URL) async -> URL? { nil }
    }

    private func records(_ folder: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }.count
    }

    @Test func aSlowReplacementKeepsSavesGoing() async throws {
        let scratch = try Scratch()
        let local = scratch.url.appendingPathComponent("Report.txt")
        try Data("initial".utf8).write(to: local)
        let saves = Gate()
        let watcher = SaveWatcher(local, delay: 0.05, queue: DispatchQueue(label: "test.saves"), reattach: { $0() }) { saves.enter() }
        defer { watcher.cancel() }
        // The editor moves the file away and writes the new one well after the debounce.
        try FileManager.default.removeItem(at: local)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(saves.count == 0)
        try Data("replaced".utf8).write(to: local)
        await expectEventually { saves.count == 1 }
        try Data("edited again".utf8).write(to: local)
        await expectEventually { saves.count == 2 }
    }
}
