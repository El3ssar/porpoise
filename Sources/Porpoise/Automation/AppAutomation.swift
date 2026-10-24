import AppKit
import PorpoiseCore
import PorpoiseServices

/// All automation joins the same UI and Activity flows as commands issued inside the app.
@MainActor final class AppAutomation {
    static let shared = AppAutomation()
    private var server: AutomationServer?
    private let windowProvider: @MainActor () -> MainWindowController?
    var window: MainWindowController? { windowProvider() }

    init(
        windowProvider: @escaping @MainActor () -> MainWindowController? = {
            (NSApp.keyWindow?.windowController as? MainWindowController)
                ?? (NSApp.mainWindow?.windowController as? MainWindowController)
                ?? AppDelegate.shared.windows.last
        }
    ) { self.windowProvider = windowProvider }

    func start() {
        guard !Settings.isTesting || TestEnvironment.defaultsSuite.isSet else { return }
        Task {
            // Endpoint creation and permission checks do not block launch/UI.
            let result = await Task.detached {
                Result { try AutomationServer { request, deadline in await Self.shared.handle(request, deadline: deadline) } }
            }.value
            if case .success(let server) = result { self.server = server }
            // A second running copy leaves the first copy's endpoint alone. No paths enter diagnostics.
        }
    }

    func handle(_ request: AutomationRequest, deadline: Date = .distantFuture) async -> AutomationResponse {
        do {
            try await Task.detached { try request.validate() }.value
            guard request.action != .runTool else { throw AutomationError.invalidRequest }
            let selected = request.action == .selection || request.useSelection ? await selectionContext() : nil
            let selection = await Task.detached { selected?.items.map(\.url) ?? [] }.value
            let urls = try await Task.detached {
                try Self.localURLs(request.paths, folders: request.action == .open || request.action == .split)
            }.value
            let destination = try await Task.detached {
                try request.destination.map { try Self.localURLs([$0], folders: true)[0] }
            }.value
            guard deadline > Date(), !Task.isCancelled else { throw AutomationError.timedOut }
            switch request.action {
            case .open:
                if let window { window.addTab(url: urls[0]) } else { AppDelegate.shared.newWindow(at: urls[0]) }
            case .split:
                if let window { window.addTab(url: urls[0], split: urls[1]) } else { AppDelegate.shared.newWindow(at: urls[0], split: urls[1]) }
            case .reveal:
                let groups = Dictionary(grouping: urls, by: { $0.deletingLastPathComponent() })
                guard groups.count <= 20 else { throw AutomationError.invalidRequest }
                for folder in groups.keys.sorted(by: { $0.path < $1.path }) {
                    if window == nil { AppDelegate.shared.newWindow(at: folder) } else { window?.addTab(url: folder) }
                    guard let view = window?.view, let items = groups[folder] else { continue }
                    view.pendingAutomationSelection = (folder, Set(items))
                    view.pendingSelect = items.first
                }
            case .selection:
                let paths = await Task.detached { selection.map { $0.isFileURL ? $0.path : $0.absoluteString } }.value
                return AutomationResponse(id: request.id, paths: paths)
            case .copy, .move:
                let sources = request.useSelection ? selection : urls
                guard !sources.isEmpty else { throw AutomationError.invalidRequest }
                FileOperationsController.shared.run(request.action == .copy ? .copy : .move, sources, to: destination, window: window?.window)
                ActivityWindowController.shared.show()
                return AutomationResponse(id: request.id, message: "Queued in Activity.")
            case .runTool: throw AutomationError.invalidRequest
            }
            return AutomationResponse(id: request.id)
        } catch {
            return AutomationResponse(
                id: request.id, error: (error as? AutomationError)?.localizedDescription ?? "The requested location is unavailable.")
        }
    }

    func selectionContext() async -> CustomToolContext? {
        guard let window else { return nil }
        let rows = window.view.model.rows, selection = window.view.model.selection
        let folder = window.view.url, other = window.tab.inactive?.url
        return await Task.detached(priority: .userInitiated) {
            CustomToolContext(folder: folder, otherFolder: other, items: rows.compactMap { selection.contains($0.item.url) ? $0.item : nil })
        }.value
    }

    nonisolated private static func localURLs(_ paths: [String], folders: Bool) throws -> [URL] {
        try paths.map { path in
            guard path.hasPrefix("/"), !path.contains("\0") else { throw AutomationError.invalidRequest }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            if folders {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw AutomationError.invalidRequest
                }
            }
            return url
        }
    }
}
