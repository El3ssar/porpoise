import CryptoKit
import Foundation
import MetricKit

/// Bounded deduplication of already projected reports, shared by cached and live delivery. No SDK objects retained.
final class MetricDiagnosticRecorder: @unchecked Sendable {
    private let store: DiagnosticStore
    private let lock = NSLock()
    private var seen: [Data] = []

    init(store: DiagnosticStore) { self.store = store }

    @discardableResult
    func receive(_ diagnostic: MetricDiagnostic, beginning: Date, ending: Date, occurrence: Int = 0) -> Bool {
        guard beginning.timeIntervalSince1970.isFinite, ending.timeIntervalSince1970.isFinite, beginning <= ending, (0..<64).contains(occurrence)
        else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(diagnostic) else { return false }
        var identity = data
        identity.append(Data("\(beginning.timeIntervalSince1970)|\(ending.timeIntervalSince1970)|\(occurrence)".utf8))
        let digest = Data(SHA256.hash(data: identity))
        return lock.withLock {
            guard !seen.contains(digest) else { return false }
            guard store.record(diagnostic) else { return false }
            seen.append(digest)
            if seen.count > 256 { seen.removeFirst(seen.count - 256) }
            return true
        }
    }
}

/// SDK payloads are immutable and callbacks may run on a background queue. Mutable registration/deduplication is
/// locked; DiagnosticStore is thread-safe. The system supplies reports when available, not on a promised schedule.
public final class MetricKitDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    public static let shared = MetricKitDiagnostics(store: Diagnostics.shared)
    private let recorder: MetricDiagnosticRecorder
    private let lock = NSLock()
    private var started = false

    public init(store: DiagnosticStore) { recorder = MetricDiagnosticRecorder(store: store) }

    /// Test launches do not subscribe. Reading cached system reports is deferred off the launch path.
    public func start() {
        guard
            lock.withLock({
                guard !started else { return false }
                started = true
                return true
            })
        else { return }
        MXMetricManager.shared.add(self)
        DispatchQueue.global(qos: .utility).async { self.consume(MXMetricManager.shared.pastDiagnosticPayloads) }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) { consume(payloads) }

    private func consume(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads.suffix(4) {
            for (index, crash) in (payload.crashDiagnostics ?? []).prefix(32).enumerated() {
                autoreleasepool {
                    let projected = MetricDiagnostic(
                        kind: .crash, applicationVersion: crash.applicationVersion,
                        signal: crash.signal?.intValue, exceptionType: crash.exceptionType?.intValue,
                        exceptionCode: crash.exceptionCode?.uint64Value, stackJSON: crash.callStackTree.jsonRepresentation(),
                        windowBeginning: payload.timeStampBegin, windowEnding: payload.timeStampEnd)
                    recorder.receive(projected, beginning: payload.timeStampBegin, ending: payload.timeStampEnd, occurrence: index)
                }
            }
            for (index, hang) in (payload.hangDiagnostics ?? []).prefix(32).enumerated() {
                autoreleasepool {
                    let projected = MetricDiagnostic(
                        kind: .hang, applicationVersion: hang.applicationVersion,
                        durationSeconds: hang.hangDuration.converted(to: .seconds).value,
                        stackJSON: hang.callStackTree.jsonRepresentation(),
                        windowBeginning: payload.timeStampBegin, windowEnding: payload.timeStampEnd)
                    recorder.receive(projected, beginning: payload.timeStampBegin, ending: payload.timeStampEnd, occurrence: index + 32)
                }
            }
        }
    }
}
