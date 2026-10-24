import AppIntents
import Foundation
import PorpoiseCore
import PorpoiseServices

private enum IntentAutomation {
    @MainActor static func perform(_ request: AutomationRequest) async throws -> AutomationResponse {
        let response = await AppAutomation.shared.handle(request)
        if let error = response.error { throw CustomToolError.invalid(error) }
        return response
    }
}

struct OpenPorpoiseLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Location in Porpoise"
    static var description = IntentDescription("Open a local folder in a new Porpoise tab. Supply an absolute folder path.")
    static var openAppWhenRun = true
    @Parameter(title: "Folder Path") var path: String
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$path) in Porpoise") }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try await IntentAutomation.perform(.init(action: .open, paths: [path]))
        return .result()
    }
}

struct GetPorpoiseSelectionIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Porpoise Selection"
    static var description = IntentDescription("Get the selected paths in the active pane. Remote selections are returned as URLs.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let response = try await IntentAutomation.perform(.init(action: .selection))
        return .result(value: response.paths)
    }
}

struct RevealInPorpoiseIntent: AppIntent {
    static var title: LocalizedStringResource = "Reveal in Porpoise"
    static var description = IntentDescription(
        "Select local files or folders in their containing folders. Supply absolute paths; up to 20 containing folders can be opened.")
    static var openAppWhenRun = true
    @Parameter(title: "Paths") var paths: [String]
    static var parameterSummary: some ParameterSummary { Summary("Reveal \(\.$paths) in Porpoise") }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try await IntentAutomation.perform(.init(action: .reveal, paths: paths))
        return .result()
    }
}

struct CopyWithPorpoiseIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy with Porpoise"
    static var description = IntentDescription(
        "Queue a copy in Activity. Conflicts and progress are handled by Porpoise. Supply absolute local paths, or use the current selection.")
    static var openAppWhenRun = true
    @Parameter(title: "Paths") var paths: [String]?
    @Parameter(title: "Use Current Selection", default: false) var useSelection: Bool
    @Parameter(title: "Destination Folder Path") var destination: String
    @MainActor func perform() async throws -> some IntentResult {
        _ = try await IntentAutomation.perform(.init(action: .copy, paths: paths ?? [], destination: destination, useSelection: useSelection))
        return .result()
    }
}

struct MoveWithPorpoiseIntent: AppIntent {
    static var title: LocalizedStringResource = "Move with Porpoise"
    static var description = IntentDescription(
        "Queue a move in Activity. Conflicts and progress are handled by Porpoise. Supply absolute local paths, or use the current selection.")
    static var openAppWhenRun = true
    @Parameter(title: "Paths") var paths: [String]?
    @Parameter(title: "Use Current Selection", default: false) var useSelection: Bool
    @Parameter(title: "Destination Folder Path") var destination: String
    @MainActor func perform() async throws -> some IntentResult {
        _ = try await IntentAutomation.perform(.init(action: .move, paths: paths ?? [], destination: destination, useSelection: useSelection))
        return .result()
    }
}

struct PorpoiseToolEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Custom Tool"
    static var defaultQuery = PorpoiseToolQuery()
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PorpoiseToolQuery: EntityQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [PorpoiseToolEntity] {
        let wanted = Set(identifiers)
        return Settings.shared.customTools.filter { wanted.contains($0.id) }.map { PorpoiseToolEntity(id: $0.id, name: $0.name) }
    }
    @MainActor func suggestedEntities() async throws -> [PorpoiseToolEntity] {
        Settings.shared.customTools.map { PorpoiseToolEntity(id: $0.id, name: $0.name) }
    }
}

struct RunPorpoiseCustomToolIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Porpoise Custom Tool"
    static var description = IntentDescription(
        "Run a tool saved in Porpoise Settings on the active folder and selection. Output and exit status appear in Activity. Large selections require confirmation."
    )
    static var openAppWhenRun = true
    @Parameter(title: "Custom Tool") var tool: PorpoiseToolEntity
    @Parameter(title: "Prompt Value") var promptValue: String?
    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$tool)") }
    @MainActor func perform() async throws -> some IntentResult {
        guard let definition = Settings.shared.customTools.first(where: { $0.id == tool.id }),
            let context = await AppAutomation.shared.selectionContext()
        else { throw AutomationError.invalidRequest }
        let reason = await Task.detached { definition.unavailableReason(in: context) }.value
        if let reason { throw CustomToolError.invalid(reason) }
        if definition.selection != .folder && context.needsConfirmation {
            try await requestConfirmation(
                dialog: "Run this custom tool on \(context.items.count) selected items? Changes made by custom tools cannot be undone by Porpoise.")
        }
        try Task.checkCancellation()
        guard Settings.shared.customTools.first(where: { $0.id == tool.id }) == definition else {
            throw CustomToolError.invalid("This tool changed while preparing it. Run the shortcut again.")
        }
        try await CustomToolRunner.shared.start(id: tool.id, context: context, value: promptValue, confirmedLargeSelection: true)
        ActivityWindowController.shared.showTools()
        return .result()
    }
}
