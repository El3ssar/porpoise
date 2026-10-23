import Foundation

/// A projection, never a raw MetricKit payload. No names, messages, paths or metadata dictionaries survive.
public struct MetricDiagnostic: Encodable, Sendable {
    public enum Kind: String, Encodable, Sendable { case crash, hang }
    public struct Frame: Encodable, Sendable {
        public let binaryUUID: UUID
        public let textOffset: UInt64
        public let samples: Int
    }

    public let windowBeginning: Date?
    public let windowEnding: Date?
    public let kind: Kind
    public let applicationVersion: String
    public let signal: Int?
    public let exceptionType: Int?
    public let exceptionCode: UInt64?
    public let durationMilliseconds: Int64?
    public let frames: [Frame]

    public init(
        kind: Kind, applicationVersion: String?, signal: Int? = nil, exceptionType: Int? = nil,
        exceptionCode: UInt64? = nil, durationSeconds: Double? = nil, stackJSON: Data? = nil,
        windowBeginning: Date? = nil, windowEnding: Date? = nil
    ) {
        if let windowBeginning, let windowEnding,
            windowBeginning.timeIntervalSince1970.isFinite, windowEnding.timeIntervalSince1970.isFinite,
            windowBeginning >= Date(timeIntervalSince1970: 0), windowBeginning <= windowEnding,
            windowEnding < Date(timeIntervalSince1970: 4_102_444_800)
        {
            self.windowBeginning = windowBeginning
            self.windowEnding = windowEnding
        } else {
            self.windowBeginning = nil
            self.windowEnding = nil
        }
        self.kind = kind
        self.applicationVersion = DiagnosticIdentity(version: applicationVersion, build: nil).version
        self.signal = signal.flatMap { (0...127).contains($0) ? $0 : nil }
        self.exceptionType = exceptionType.flatMap { (0...127).contains($0) ? $0 : nil }
        self.exceptionCode = exceptionCode
        if let durationSeconds, durationSeconds.isFinite, durationSeconds >= 0 {
            durationMilliseconds = Int64(min(durationSeconds, 7 * 24 * 60 * 60) * 1000)
        } else {
            durationMilliseconds = nil
        }
        frames = Self.projectFrames(stackJSON)
    }

    private static func projectFrames(_ data: Data?) -> [Frame] {
        guard let data, data.count <= 2 * 1024 * 1024,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let stacks = ((root["callStackTree"] as? [String: Any]) ?? root)["callStacks"] as? [[String: Any]]
        else { return [] }
        var pending: [([String: Any], Int)] = []
        for stack in stacks.prefix(16) {
            for frame in (stack["callStackRootFrames"] as? [[String: Any]] ?? []).prefix(64) { pending.append((frame, 0)) }
        }
        var result: [Frame] = [], visited = 0
        while let (frame, depth) = pending.popLast(), visited < 512, result.count < 64 {
            visited += 1
            if let text = frame["binaryUUID"] as? String, text.utf8.count == 36, let uuid = UUID(uuidString: text),
                let offset = frame["offsetIntoBinaryTextSegment"] as? NSNumber,
                CFGetTypeID(offset) != CFBooleanGetTypeID(), offset.doubleValue.isFinite,
                offset.doubleValue >= 0, offset.doubleValue < Double(UInt64.max),
                offset.doubleValue.rounded(.towardZero) == offset.doubleValue
            {
                let count = frame["sampleCount"] as? NSNumber
                let samples =
                    count.flatMap { value -> Int? in
                        guard CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
                        return Int(min(1_000_000, max(1, value.doubleValue)))
                    } ?? 1
                result.append(Frame(binaryUUID: uuid, textOffset: offset.uint64Value, samples: samples))
            }
            if depth < 31 {
                for child in (frame["subFrames"] as? [[String: Any]] ?? []).prefix(64) { pending.append((child, depth + 1)) }
            }
        }
        return result
    }
}
