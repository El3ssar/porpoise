import Foundation

/// Scalar-based filename grammar shared by local actions, remote commands and name dialogs.
public enum FileName {
    public enum Context: Equatable, Sendable {
        /// An untrusted listing component; its server may support names longer than this Mac does.
        case component
        /// One local filename (POSIX permits line breaks).
        case local
        /// One protocol operand; CR/LF could split commands. Server-specific lengths remain server-owned.
        case remote
        /// A relative local path whose components become nested folders.
        case multiComponent
    }

    public enum NameProblem: Equatable, Sendable {
        case empty, dot, separator, nul, newline, tooLong, hidden, whitespace, nestedFolders

        public var isError: Bool {
            switch self {
            case .hidden, .whitespace, .nestedFolders: return false
            default: return true
            }
        }

        public func message(for name: String) -> String {
            switch self {
            case .empty: return ""
            case .dot: return "“\(name)” is not a valid name."
            case .separator: return "A name cannot contain “/”."
            case .nul: return "A name cannot contain a NUL character."
            case .newline: return "A remote name cannot contain a line break."
            case .tooLong: return "A filename cannot exceed 255 UTF-8 bytes."
            case .hidden: return "The name starts with a dot, so it will be hidden by default."
            case .whitespace: return "The name has leading or trailing spaces."
            case .nestedFolders: return "Using slashes in the name will create subfolders."
            }
        }
    }

    /// Warnings are returned after all structural errors; they do not make a component unsafe.
    public static func validate(_ name: String, for context: Context) -> NameProblem? {
        guard !name.isEmpty else { return .empty }
        let scalars = name.unicodeScalars
        if scalars.contains("\0") { return .nul }
        if context == .remote && (scalars.contains("\n") || scalars.contains("\r")) { return .newline }
        let components: [String]
        if context == .multiComponent {
            if scalars.first == "/" { return .separator }
            components = name.scalarComponents(separatedBy: "/")
            if components.isEmpty { return .empty }
        } else {
            if scalars.contains("/") { return .separator }
            components = [name]
        }
        if components.contains(where: { $0 == "." || $0 == ".." }) { return .dot }
        if (context == .local || context == .multiComponent) && components.contains(where: { $0.utf8.count > 255 }) { return .tooLong }
        if scalars.first == "." { return .hidden }
        if context == .multiComponent && scalars.contains("/") { return .nestedFolders }
        if name != name.trimmingCharacters(in: .whitespaces) { return .whitespace }
        return nil
    }

    public static func isValid(_ name: String, for context: Context) -> Bool {
        validate(name, for: context)?.isError != true
    }
}
