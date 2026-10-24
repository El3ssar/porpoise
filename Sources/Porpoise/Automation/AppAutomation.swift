import AppKit
import PorpoiseCore
import PorpoiseServices

/// All automation joins the same UI and Activity flows as commands issued inside the app.
@MainActor final class AppAutomation {
    static let shared = AppAutomation()
    private var server: AutomationServer?
    private var observation: NSObjectProtocol?
    private var generation = 0
    typealias Approval = @MainActor ([URL], URL, AutomationRequest.Action, NSWindow?, Date) async -> Bool
    var approveTransfer: Approval
    private let windowProvider: @MainActor () -> MainWindowController?
    var window: MainWindowController? { windowProvider() }

    init(
        windowProvider: @escaping @MainActor () -> MainWindowController? = {
            (NSApp.keyWindow?.windowController as? MainWindowController)
                ?? (NSApp.mainWindow?.windowController as? MainWindowController)
                ?? AppDelegate.shared.windows.last
        },
        approval: @escaping Approval = { sources, destination, action, window, deadline in
            await AppAutomation.confirmTransfer(sources, destination: destination, action: action, window: window, deadline: deadline)
        }
    ) { self.windowProvider = windowProvider; self.approveTransfer = approval }

    func start() {
        if observation == nil {
            observation = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] note in
                guard note.object == nil || note.object as? String == "allowCommandLineControl" else { return }
                Task { @MainActor in self?.updateServer() }
            }
        }
        updateServer()
    }

    private func updateServer() {
        generation += 1
        let current = generation
        server?.stop(); server = nil
        guard Settings.shared.allowCommandLineControl else { return }
        Task {
            let result = await Task.detached {
                Result {
                    try AutomationServer { request, deadline in
                        await Self.shared.handle(request, deadline: deadline, commandLine: true)
                    }
                }
            }.value
            if case .success(let server) = result {
                guard current == generation, Settings.shared.allowCommandLineControl else { server.stop(); return }
                self.server = server
            }
        }
    }

    func handle(_ request: AutomationRequest, deadline: Date = .distantFuture, commandLine: Bool = false) async -> AutomationResponse {
        do {
            guard !commandLine || Settings.shared.allowCommandLineControl else { throw AutomationError.unavailable }
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
            guard deadline > Date(), !Task.isCancelled, !commandLine || Settings.shared.allowCommandLineControl else {
                throw AutomationError.timedOut
            }
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
                guard !commandLine || Settings.shared.allowCommandLineControl else { throw AutomationError.unavailable }
                return AutomationResponse(id: request.id, paths: paths)
            case .copy, .move:
                let sources = request.useSelection ? selection : urls
                guard !sources.isEmpty else { throw AutomationError.invalidRequest }
                guard let destination else { throw AutomationError.invalidRequest }
                if window == nil { AppDelegate.shared.newWindow(at: destination) }
                let operations = FileOperationsController.shared
                let pending = operations.queueAutomation(
                    request.action == .copy ? .copy : .move, sources: sources, destination: destination, window: window?.window)
                let approvalDeadline = Date().addingTimeInterval(120)
                Task {
                    let approved = await approveTransfer(sources, destination, request.action, window?.window, approvalDeadline)
                    let allowed =
                        approved && approvalDeadline > Date() && !Task.isCancelled
                        && (!commandLine || Settings.shared.allowCommandLineControl)
                    operations.finishAutomationApproval(pending, approved: allowed)
                }
                ActivityWindowController.shared.show()
                return AutomationResponse(id: request.id, message: "Queued in Activity; awaiting approval in Porpoise.")
            case .runTool: throw AutomationError.invalidRequest
            }
            return AutomationResponse(id: request.id)
        } catch {
            return AutomationResponse(
                id: request.id, error: (error as? AutomationError)?.localizedDescription ?? "The requested location is unavailable.")
        }
    }

    static func confirmTransfer(_ sources: [URL], destination: URL, action: AutomationRequest.Action, window: NSWindow?, deadline: Date) async -> Bool
    {
        guard let window, window.attachedSheet == nil, deadline > Date() else { return false }
        let alert = NSAlert()
        alert.messageText = "Allow an automation request to \(action.rawValue) \(sources.count) items?"
        alert.informativeText =
            "A command-line request or Shortcut wants to transfer these items using Porpoise’s access. Administrator access is never used.\n\n"
            + sources.prefix(10).map { $0.isFileURL ? $0.path : $0.absoluteString }.joined(separator: "\n")
            + (sources.count > 10 ? "\n…" : "") + "\n\nDestination: " + destination.path
        alert.addButton(withTitle: "Allow Transfer"); alert.addButton(withTitle: "Cancel")
        window.orderFront(nil)
        return await withCheckedContinuation { continuation in
            let timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, min(120, deadline.timeIntervalSinceNow)) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                window.endSheet(alert.window, returnCode: .abort)
            }
            alert.beginSheetModal(for: window) { response in
                timer.cancel()
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
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
