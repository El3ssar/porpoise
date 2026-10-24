import Foundation

/// Local automation carries data only. Executable commands always come from the app's saved tools.
public struct AutomationRequest: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case open, split, reveal, selection, copy, move, runTool }
    public var version: Int = 1
    public var id: UUID
    public var action: Action
    public var paths: [String]
    public var destination: String?
    public var useSelection: Bool
    public var toolID: UUID?
    public var promptValue: String?

    public init(
        action: Action, paths: [String] = [], destination: String? = nil, useSelection: Bool = false,
        toolID: UUID? = nil, promptValue: String? = nil, id: UUID = UUID()
    ) {
        self.id = id
        self.action = action
        self.paths = paths
        self.destination = destination
        self.useSelection = useSelection
        self.toolID = toolID
        self.promptValue = promptValue
    }

    public func validate() throws {
        guard version == 1, paths.count <= 100_000,
            paths.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }),
            destination.map({ !$0.isEmpty && !$0.contains("\0") }) ?? true,
            (promptValue?.utf8.count ?? 0) <= 65_536
        else { throw AutomationError.invalidRequest }
        guard action == .copy || action == .move || (destination == nil && !useSelection),
            action == .runTool || (toolID == nil && promptValue == nil)
        else { throw AutomationError.invalidRequest }
        switch action {
        case .open: guard paths.count == 1 else { throw AutomationError.invalidRequest }
        case .split: guard paths.count == 2 else { throw AutomationError.invalidRequest }
        case .reveal: guard !paths.isEmpty else { throw AutomationError.invalidRequest }
        case .selection: guard paths.isEmpty else { throw AutomationError.invalidRequest }
        case .copy, .move:
            guard destination != nil, useSelection ? paths.isEmpty : !paths.isEmpty else { throw AutomationError.invalidRequest }
        case .runTool: guard toolID != nil, paths.isEmpty else { throw AutomationError.invalidRequest }
        }
    }
}

public struct AutomationResponse: Codable, Sendable, Equatable {
    public var version = 1
    public var id: UUID
    public var paths: [String]
    public var message: String?
    public var error: String?

    public init(id: UUID, paths: [String] = [], message: String? = nil, error: String? = nil) {
        self.id = id
        self.paths = paths
        self.message = message
        self.error = error
    }
}

public enum AutomationError: String, Error, LocalizedError, Sendable {
    case invalidRequest, unavailable, unsafeEndpoint, busy, timedOut, oversized, invalidResponse
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Invalid automation request. Check the supplied paths and options."
        case .unavailable: return "Porpoise is not available. Start the app and try again."
        case .unsafeEndpoint: return "The local automation endpoint is not secure."
        case .busy: return "Another Porpoise instance already owns the automation endpoint."
        case .timedOut: return "Porpoise did not respond in time. Check Activity before retrying a copy or move."
        case .oversized: return "The automation request or response is too large."
        case .invalidResponse: return "Porpoise returned an invalid automation response."
        }
    }
}
