import Foundation
import PorpoiseCore
import UniformTypeIdentifiers

public struct FinderQuickAction: Equatable, Sendable {
    public let url: URL
    public let name: String
    public let iconName: String
    public let iconData: Data?
    let inputTypes: [String]

    func accepts(_ types: Set<String>) -> Bool {
        let accepted = inputTypes.compactMap { UTType($0) }
        return !types.isEmpty
            && types.allSatisfy { type in
                guard let type = UTType(type) else { return false }
                return accepted.contains { type.conforms(to: $0) }
            }
    }
}

/// Read installed file workflows. Call these methods outside the main thread.
public struct FinderQuickActions: Sendable {
    private let directories: [URL]
    private let languages: [String]
    private let applicationIdentifier: String
    private let contextMenuStates: [String: Bool]?

    public init(directories: [URL]? = nil, languages: [String] = Locale.preferredLanguages, contextMenuStates: [String: Bool]? = nil) {
        self.directories =
            directories
            ?? (Settings.isTesting
                ? []
                : [
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services"),
                    URL(fileURLWithPath: "/Library/Services", isDirectory: true),
                    URL(fileURLWithPath: "/System/Library/Services", isDirectory: true),
                ])
        self.languages = languages
        self.contextMenuStates = contextMenuStates
        applicationIdentifier = Bundle.main.bundleIdentifier ?? "app.porpoise"
    }

    public func actions(for items: [FileItem]) -> [FinderQuickAction] {
        guard !items.isEmpty, items.allSatisfy({ $0.url.isFileURL }) else { return [] }
        let types = Set(items.map { $0.contentType ?? UTType.data.identifier })
        let states = contextMenuStates ?? Self.storedContextMenuStates()
        var seen = Set<String>(), result: [FinderQuickAction] = []
        for directory in directories {
            let urls =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for url in urls where url.pathExtension.lowercased() == "workflow" {
                guard seen.insert(url.lastPathComponent.lowercased()).inserted,
                    let action = read(url, states: states), action.accepts(types)
                else { continue }
                result.append(action)
            }
        }
        return result.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
    }

    public static func unavailableReason(for items: [FileItem]) -> String? {
        guard !items.isEmpty, items.allSatisfy({ $0.url.isFileURL }) else { return "Select local files or folders." }
        // Automator splits path strings at line breaks before it passes arguments to a shell action.
        if items.contains(where: { $0.url.path.rangeOfCharacter(from: .newlines) != nil }) {
            return "Automator cannot receive file names that contain line breaks."
        }
        return nil
    }

    public func run(_ action: FinderQuickAction, on items: [FileItem]) async throws {
        if let reason = Self.unavailableReason(for: items) { throw QuickActionError(reason) }
        // Read the installed workflow again. The menu can remain open while the user changes the workflow.
        guard directories.contains(where: { $0.standardizedFileURL == action.url.deletingLastPathComponent().standardizedFileURL }),
            let current = read(action.url, states: contextMenuStates ?? Self.storedContextMenuStates()),
            current.accepts(Set(items.map { $0.contentType ?? UTType.data.identifier }))
        else { throw QuickActionError("This Quick Action is no longer available for these items.") }
        let task = try NSUserAutomatorTask(url: current.url)
        _ = try await task.execute(withInput: items.map { $0.url.path } as NSArray)
    }

    static func contextMenuStates(in status: [String: [String: Any]]) -> [String: Bool] {
        status.compactMapValues { entry in
            (entry["presentation_modes"] as? [String: Any])?["ContextMenu"] as? Bool ?? entry["enabled_context_menu"] as? Bool
        }
    }

    private static func storedContextMenuStates() -> [String: Bool] {
        guard !Settings.isTesting else { return [:] }
        // macOS stores these choices in the pbs domain. Read changes made in System Settings.
        CFPreferencesAppSynchronize("pbs" as CFString)
        let status = CFPreferencesCopyAppValue("NSServicesStatus" as CFString, "pbs" as CFString) as? [String: [String: Any]] ?? [:]
        return contextMenuStates(in: status)
    }

    private func read(_ url: URL, states: [String: Bool]) -> FinderQuickAction? {
        let info = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let services = plist["NSServices"] as? [[String: Any]],
            ["Contents/document.wflow", "Contents/Resources/document.wflow"].contains(where: {
                FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
            })
        else { return nil }
        var types: [String] = [], name: String?, iconName = "NSActionTemplate"
        for service in services {
            guard service["NSMessage"] as? String == "runWorkflowAsService", allowsFinder(service["NSRequiredContext"]) else { continue }
            let title = (service["NSMenuItem"] as? [String: String])?["default"] ?? url.deletingPathExtension().lastPathComponent
            let key = "\(plist["CFBundleIdentifier"] as? String ?? "(null)") - \(title) - runWorkflowAsService"
            // A service without NSRequiredContext stays hidden until the user enables it.
            guard states[key] ?? (service["NSRequiredContext"] != nil) else { continue }
            var inputTypes = service["NSSendFileTypes"] as? [String] ?? []
            let sendTypes = service["NSSendTypes"] as? [String] ?? []
            if sendTypes.contains("NSFilenamesPboardType") || sendTypes.contains("public.file-url") {
                inputTypes.append(UTType.item.identifier)
            }
            guard !inputTypes.isEmpty else { continue }
            types += inputTypes
            if name == nil, let titles = service["NSMenuItem"] as? [String: String] {
                name = localizedName(titles, at: url)
                iconName = service["NSIconName"] as? String ?? "NSActionTemplate"
            }
        }
        guard !types.isEmpty else { return nil }
        return FinderQuickAction(
            url: url, name: name ?? url.deletingPathExtension().lastPathComponent,
            iconName: iconName, iconData: iconData(named: iconName, at: url), inputTypes: types)
    }

    private func iconData(named name: String, at url: URL) -> Data? {
        guard name == (name as NSString).lastPathComponent, let bundle = Bundle(url: url) else { return nil }
        for ext: String? in [nil, "tiff", "tif", "png", "pdf", "icns", "jpg", "jpeg"] {
            if let resource = bundle.url(forResource: name, withExtension: ext), let data = try? Data(contentsOf: resource) { return data }
        }
        return nil
    }

    private func localizedName(_ titles: [String: String], at url: URL) -> String? {
        let preferred = Bundle.preferredLocalizations(from: Array(titles.keys), forPreferences: languages + ["default"])
        guard let name = preferred.compactMap({ titles[$0] }).first ?? titles["default"] else { return nil }
        guard name == titles["default"], let bundle = Bundle(url: url),
            let language = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: languages).first,
            let table = bundle.url(forResource: "ServicesMenu", withExtension: "strings", subdirectory: nil, localization: language),
            let data = try? Data(contentsOf: table),
            let strings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return name }
        return strings[name] ?? name
    }

    private func allowsFinder(_ value: Any?) -> Bool {
        guard let value else { return true }
        let contexts = (value as? [[String: Any]]) ?? (value as? [String: Any]).map { [$0] } ?? []
        return contexts.contains { context in
            guard let value = context["NSApplicationIdentifier"] else { return true }
            let identifiers = value as? [String] ?? (value as? String).map { [$0] } ?? []
            return identifiers.contains("com.apple.finder") || identifiers.contains(applicationIdentifier)
        }
    }
}

private struct QuickActionError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
