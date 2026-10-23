import Foundation
import UniformTypeIdentifiers

public enum CustomToolError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

/// Stored only in the user's preferences. Arguments are templates, never a shell command line.
public struct CustomTool: Codable, Sendable, Equatable, Identifiable {
    public enum Targets: String, Codable, CaseIterable, Sendable { case files, folders, both }
    public enum Selection: String, Codable, CaseIterable, Sendable { case folder, one, many }
    public enum Placement: String, Codable, CaseIterable, Sendable { case contextMenu, toolbar, commandPalette }
    public var id: UUID
    public var name: String
    public var executable: String
    public var arguments: [String]
    public var targets: Targets = .both
    public var selection: Selection = .many
    public var extensions: [String] = []
    public var types: [String] = []
    public var placements: Set<Placement> = [.contextMenu, .commandPalette]
    public var prompt: String = ""
    public var shortcut = KeyboardShortcut()
    public init(id: UUID = UUID(), name: String, executable: String, arguments: [String]) {
        self.id = id; self.name = name; self.executable = executable; self.arguments = arguments
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120, !name.contains("\0"),
            executable.hasPrefix("/"), executable.utf8.count <= 4096, !executable.contains("\0"), !executable.contains("{"),
            arguments.count <= 1024, arguments.reduce(0, { $0 + $1.utf8.count + 1 }) <= 128 * 1024,
            arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 65_536 }),
            extensions.count <= 100, types.count <= 100, prompt.count <= 500, !prompt.contains("\0")
        else { throw CustomToolError.invalid("Enter a name, an absolute executable path and valid arguments.") }
        guard extensions.allSatisfy({ !$0.isEmpty && !$0.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "." }) }),
            types.allSatisfy({ UTType($0) != nil })
        else { throw CustomToolError.invalid("Use extensions without dots and valid type identifiers (such as public.image).") }
        for argument in arguments {
            if argument.contains("{selection}"), argument != "{selection}" {
                throw CustomToolError.invalid("{selection} must be an entire argument; it expands to one argument per selected item.")
            }
            var remaining = argument
            for token in ["{selection}", "{folder}", "{otherFolder}", "{prompt}"] { remaining = remaining.replacingOccurrences(of: token, with: "") }
            guard !remaining.contains("{"), !remaining.contains("}") else { throw CustomToolError.invalid("Unknown placeholder in arguments.") }
        }
        // Script source is code, even when passed as argv. Paths/values may only enter a shell as positional data.
        if ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"].contains((executable as NSString).lastPathComponent) {
            for (index, argument) in arguments.enumerated() {
                let evaluates = argument == "--command" || (argument.hasPrefix("-") && !argument.hasPrefix("--") && argument.contains("c"))
                if evaluates, arguments.indices.contains(index + 1), arguments[index + 1].contains("{") {
                    throw CustomToolError.invalid(
                        "Do not put placeholders in shell source. Use a script file and pass placeholders as separate arguments.")
                }
                if argument.hasPrefix("--command="), argument.contains("{") {
                    throw CustomToolError.invalid("Do not put placeholders in shell source.")
                }
            }
        }
        if arguments.contains(where: { $0.contains("{prompt}") }), prompt.isEmpty {
            throw CustomToolError.invalid("Give the value prompt a label before using {prompt}.")
        }
        if selection == .folder, arguments.contains("{selection}") {
            throw CustomToolError.invalid("A current-folder tool uses {folder}, rather than {selection}.")
        }
        try shortcut.validate()
    }

    /// Pure matching: uses the listing's metadata, never stats files or follows links on the UI thread.
    public func unavailableReason(in context: CustomToolContext) -> String? {
        guard context.folder.isFileURL else { return "Custom tools require a local folder." }
        let items = context.items
        if selection == .one && items.count != 1 { return "Select exactly one item." }
        if selection == .many && items.isEmpty { return "Select one or more items." }
        if arguments.contains(where: { $0.contains("{otherFolder}") }), context.otherFolder?.isFileURL != true {
            return "Open a local folder in the other split pane."
        }
        let targets = selection == .folder ? [FileItem(url: context.folder, name: "", isDirectory: true)] : items
        let extensions = Set(extensions.map { $0.lowercased() })
        let types = types.compactMap(UTType.init)
        for item in targets {
            guard item.url.isFileURL else { return "Custom tools require local items." }
            if self.targets == .files && item.isDirectory || self.targets == .folders && !item.isDirectory {
                return self.targets == .files ? "This tool applies to files." : "This tool applies to folders."
            }
            if !extensions.isEmpty || !types.isEmpty {
                let matchesExtension = extensions.contains(item.fileExtension.lowercased())
                let matchesType = item.utType.map { actual in types.contains { actual.conforms(to: $0) } } ?? false
                if !matchesExtension && !matchesType { return "The selected types do not match this tool." }
            }
        }
        return nil
    }
    public func invocation(in context: CustomToolContext, value: String? = nil) throws -> CustomToolInvocation {
        try validate()
        if let reason = unavailableReason(in: context) { throw CustomToolError.invalid(reason) }
        if !prompt.isEmpty && value == nil { throw CustomToolError.invalid("This tool needs a value.") }
        guard value?.contains("\0") != true else { throw CustomToolError.invalid("The value contains an invalid character.") }
        var args: [String] = []
        for argument in arguments {
            if argument == "{selection}" { args += context.items.map { $0.url.path }; continue }
            // One pass: a filename/value that contains a placeholder is always literal data.
            var result = "", rest = argument[...]
            while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
                result += rest[..<open]
                switch rest[open...close] {
                case "{folder}": result += context.folder.path
                case "{otherFolder}": result += context.otherFolder?.path ?? ""
                case "{prompt}": result += value ?? ""
                default: break
                }
                rest = rest[rest.index(after: close)...]
            }
            result += rest; args.append(result)
        }
        // Stay comfortably below macOS ARG_MAX; report a useful error instead of truncating a selection.
        guard args.reduce(executable.utf8.count + 1, { $0 + $1.utf8.count + 1 }) <= 128 * 1024 else {
            throw CustomToolError.invalid("The selection is too large for one command. Select fewer items.")
        }
        return CustomToolInvocation(executable: executable, arguments: args, folder: context.folder)
    }
}

public struct CustomToolContext: Sendable {
    public let folder: URL
    public let otherFolder: URL?
    public let items: [FileItem]
    public init(folder: URL, otherFolder: URL? = nil, items: [FileItem]) { self.folder = folder; self.otherFolder = otherFolder; self.items = items }
    public var needsConfirmation: Bool { items.count > 100 }
}
public struct CustomToolInvocation: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let folder: URL
}

public struct CustomToolDocument: Codable, Sendable, Equatable {
    public var version = 1
    public var tools: [CustomTool]
    public init(tools: [CustomTool]) { self.tools = tools }
    public func validate() throws {
        guard version == 1, tools.count <= 200, Set(tools.map(\.id)).count == tools.count else {
            throw CustomToolError.invalid("Unsupported tool file, duplicate identifiers, or more than 200 tools.")
        }
        for tool in tools { try tool.validate() }
        let keys = tools.map(\.shortcut).filter { !$0.isEmpty }.map(\.normalized)
        guard Set(keys).count == keys.count else { throw CustomToolError.invalid("Two tools use the same shortcut.") }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2 * 1024 * 1024 else { throw CustomToolError.invalid("The tools file is too large.") }
        let document = try JSONDecoder().decode(Self.self, from: data); try document.validate(); return document
    }
    public func encoded() throws -> Data {
        try validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 2 * 1024 * 1024 else { throw CustomToolError.invalid("The tools file is too large.") }
        return data
    }
    public static var examples: [CustomTool] {
        var checksum = CustomTool(name: "SHA-256", executable: "/usr/bin/shasum", arguments: ["-a", "256", "--", "{selection}"])
        checksum.targets = .files
        var list = CustomTool(name: "List Current Folder", executable: "/bin/ls", arguments: ["-la", "--", "{folder}"])
        list.selection = .folder; list.targets = .folders
        var find = CustomTool(name: "Find Text", executable: "/usr/bin/grep", arguments: ["-n", "-e", "{prompt}", "--", "{selection}"])
        find.targets = .files; find.prompt = "Text to find"
        return [checksum, list, find]
    }
}
