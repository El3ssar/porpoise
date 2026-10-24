import Foundation

/// Paths as the authorization dialog shows them. A name can hold a line break, a right-to-left override or
/// invisible characters, or be very long: none of that may make the dialog read as something other than what will
/// be done, or push the real path out of sight.
public enum HelperDisplay {
    /// Longest path shown, in characters (the last component is kept whole when it fits).
    static let limit = 120

    /// `path` in quotes, controls and invisible or direction-changing characters written as escapes, long ones cut
    /// in the middle.
    public static func path(_ path: String) -> String { quoted(shortened(path)) }

    static func shortened(_ path: String) -> String {
        guard path.count > limit else { return path }
        var last = (path as NSString).lastPathComponent
        if last.count > limit - 20 {
            let keep = limit - 21
            last = String(last.prefix(keep / 2 + keep % 2)) + "…" + String(last.suffix(keep / 2))
            return "…/" + last
        }
        return String(path.prefix(limit - last.count - 2)) + "…/" + last
    }

    static func quoted(_ text: String) -> String {
        var result = "“"
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x5c: result += "\\\\"
            case 0x0a: result += "\\n"
            case 0x0d: result += "\\r"
            case 0x09: result += "\\t"
            default:
                // Spaces other than the plain one (no-break, zero-width…) would hide where a name ends.
                let category = scalar.properties.generalCategory
                if [.control, .format, .lineSeparator, .paragraphSeparator].contains(category) || category == .spaceSeparator && scalar.value != 0x20
                {
                    result += "\\u{" + String(scalar.value, radix: 16) + "}"
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "”"
    }
}

/// The text of the authorization dialog, made by the helper from the requests it validated: what the person
/// approves is what will be done.
enum HelperPrompt {
    struct Item {
        let verb: String
        /// What it acts on, then (for a move or copy) where to.
        let paths: [String]
        let tier: HelperTier
        let reason: String?

        var shown: String { verb + " " + paths.map(HelperDisplay.path).joined(separator: " to ") }
    }

    /// Shown in a standard prompt; in a protected one every protected item comes first, up to `protectedShown`.
    static let standardShown = 3
    static let protectedShown = 8

    static func text(_ items: [Item], tier: HelperTier) -> String {
        let protected = items.filter { $0.tier >= .protected }
        let others = items.filter { $0.tier < .protected }
        var lines: [String] = []
        if tier >= .protected {
            lines = protected.prefix(protectedShown).map { "\($0.shown), which \($0.reason ?? "is protected")" }
            if protected.count > protectedShown { lines.append("and \(protected.count - protectedShown) more protected items") }
            if !others.isEmpty { lines.append("and \(others.count) other item\(others.count == 1 ? "" : "s")") }
        } else {
            lines = others.prefix(standardShown).map(\.shown)
            if others.count > standardShown { lines.append("and \(others.count - standardShown) more") }
        }
        var text = "Porpoise wants to " + lines.joined(separator: ",\n")
        text += "."
        if protected.contains(where: { $0.reason == HelperPolicy.startupReason }) {
            text += "\n\nThis can change what runs when your Mac starts."
        } else if protected.contains(where: { $0.reason == HelperPolicy.settingsReason }) {
            text += "\n\nThis changes system settings."
        }
        return text
    }

    /// What `op` does, as the dialog says it. `trash` is the asking person's Trash.
    static func verb(_ op: HelperOperation, trash: String?) -> String {
        switch op {
        case .move(_, let destination, _):
            if let trash, (HelperRequests.resolvedParent(destination) as NSString).deletingLastPathComponent == trash { return "move to the Trash" }
            return "move"
        case .copy: return "copy"
        case .link: return "make a link at"
        case .mkdir: return "create"
        case .chmod: return "change the permissions of"
        case .remove: return "delete"
        case .unlock: return "unlock"
        case .chown: return "change the owner of"
        case .setFlag: return "change the locks of"
        }
    }
}
