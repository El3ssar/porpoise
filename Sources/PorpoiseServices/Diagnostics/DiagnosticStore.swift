import Foundation

/// A reviewed snapshot. Preview and local export use exactly these immutable bytes; no later events are added.
public struct DiagnosticExport: Sendable {
    public let data: Data
    public var text: String { String(decoding: data, as: UTF8.self) }

    fileprivate init(data: Data) { self.data = data }

    public enum Failure: Error, Equatable {
        case localFileRequired, invalidClock
    }

    /// Writes only a new local file. The chosen filename is never added to events or to the export itself.
    /// There is no upload operation and an existing file is never replaced. A failed write is reported to callers.
    public func write(to url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw Failure.localFileRequired
        }
        try data.write(to: url, options: .withoutOverwriting)
    }
}

/// Bounded process-memory storage: no singleton, implicit disk file, network client or automatic collection.
/// Instrumentation chooses a fixed code/category; this store never retains the input Error or its description.
public final class DiagnosticStore: @unchecked Sendable {
    public struct Limits: Sendable {
        public let maximumEvents: Int
        public let maximumBytes: Int
        public let maximumAge: TimeInterval

        public init(maximumEvents: Int = 256, maximumBytes: Int = 256 * 1024, maximumAge: TimeInterval = 24 * 60 * 60) {
            self.maximumEvents = min(1000, max(0, maximumEvents))
            self.maximumBytes = min(1024 * 1024, max(1024, maximumBytes))
            self.maximumAge = maximumAge.isFinite ? min(7 * 24 * 60 * 60, max(1, maximumAge)) : 24 * 60 * 60
        }
    }

    private struct Snapshot: Encodable {
        /// 3: optional, strictly projected MetricKit crash/hang details.
        let schemaVersion = 3
        let identity: DiagnosticIdentity
        let generatedAt: Date
        let events: [DiagnosticEvent]
    }

    private let lock = NSLock()
    private let identity: DiagnosticIdentity
    private let limits: Limits
    private let now: @Sendable () -> Date
    // All mutable state is protected by lock. No caller-provided callbacks run while it is held except the internal
    // clock used by deterministic tests; public instances always use Date.init.
    private var events: [DiagnosticEvent] = []

    public convenience init(identity: DiagnosticIdentity = .current, limits: Limits = Limits()) {
        self.init(identity: identity, limits: limits, now: { Date() })
    }

    init(identity: DiagnosticIdentity, limits: Limits, now: @escaping @Sendable () -> Date) {
        self.identity = identity
        self.limits = limits
        self.now = now
    }

    /// Returns false when disabled or unable to produce a valid bounded event. Diagnostic failure must not mask
    /// the operation's own result. Each operation should generate one correlation and reuse it for related events.
    @discardableResult
    public func record(
        _ code: DiagnosticEvent.Code, failure: DiagnosticFailure = .none, correlation: DiagnosticCorrelation = .init()
    ) -> Bool {
        record(code, failure: failure, correlation: correlation, diagnostic: nil)
    }

    private func record(
        _ code: DiagnosticEvent.Code, failure: DiagnosticFailure, correlation: DiagnosticCorrelation = .init(), diagnostic: MetricDiagnostic?
    ) -> Bool {
        return lock.withLock {
            let timestamp = now()
            guard timestamp.timeIntervalSince1970.isFinite else { return false }
            events.append(DiagnosticEvent(timestamp: timestamp, code: code, failure: failure, correlation: correlation, diagnostic: diagnostic))
            do {
                _ = try bound(at: timestamp)
                return !events.isEmpty
            } catch {
                events.removeAll()
                return false
            }
        }
    }

    @discardableResult
    public func record(_ code: DiagnosticEvent.Code, error: any Error, correlation: DiagnosticCorrelation = .init()) -> Bool {
        record(code, failure: DiagnosticFailure(error: error), correlation: correlation)
    }

    /// Only the reviewed projection can add crash/hang details; arbitrary dictionaries are never accepted.
    @discardableResult
    public func record(_ diagnostic: MetricDiagnostic) -> Bool {
        record(
            diagnostic.kind == .crash ? .appCrash : .appHang,
            failure: diagnostic.kind == .crash ? .unknown : .timeout, diagnostic: diagnostic)
    }

    /// Expired/future events are removed before every preview as well as every record. Passing a set restricts the
    /// review to those operation correlations; an empty set exports no events. nil reviews all retained events.
    public func preview(correlations: Set<DiagnosticCorrelation>? = nil) throws -> DiagnosticExport {
        return try lock.withLock {
            let timestamp = now()
            guard timestamp.timeIntervalSince1970.isFinite else { throw DiagnosticExport.Failure.invalidClock }
            let all = try bound(at: timestamp)
            guard let correlations else { return DiagnosticExport(data: all) }
            let selected = events.filter { correlations.contains($0.correlation) }
            return DiagnosticExport(data: try encode(selected, at: timestamp))
        }
    }

    public func clear() { lock.withLock { events.removeAll() } }

    /// Called with the lock held. The byte cap includes the complete export envelope, metadata and JSON syntax.
    private func bound(at timestamp: Date) throws -> Data {
        events.removeAll {
            let age = timestamp.timeIntervalSince($0.timestamp)
            return age < 0 || age > limits.maximumAge
        }
        if events.count > limits.maximumEvents { events.removeFirst(events.count - limits.maximumEvents) }
        var data = try encode(events, at: timestamp)
        while data.count > limits.maximumBytes && !events.isEmpty {
            events.removeFirst()
            data = try encode(events, at: timestamp)
        }
        return data
    }

    private func encode(_ selected: [DiagnosticEvent], at timestamp: Date) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(Snapshot(identity: identity, generatedAt: timestamp, events: selected))
    }
}
