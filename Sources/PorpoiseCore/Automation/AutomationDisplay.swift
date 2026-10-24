import Foundation

/// Unambiguous paths in an approval prompt: control/format scalars cannot introduce rows or reverse labels.
public enum AutomationDisplay {
    public static func quotedPath(_ path: String) -> String {
        var result = "\""
        for scalar in path.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0x0a: result += "\\n"
            case 0x0d: result += "\\r"
            case 0x09: result += "\\t"
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator:
                    result += "\\u{" + String(scalar.value, radix: 16) + "}"
                default: result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
