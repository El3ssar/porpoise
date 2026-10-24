import Foundation

/// Legacy XPC arrays are decoded once, then never used as executable paths or command-line arguments.
enum HelperOperation {
    case move(String, String, noReplace: Bool)
    case copy(String, String, recursive: Bool)
    case link(String, String)
    case mkdir(String)
    case chmod(String, mode_t)
    case remove(String)
    case unlock(String)
    case chown(String, uid_t, gid_t)
    /// One flag set or cleared on the item itself (never a link's target): see `HelperRequests.settableFlags`.
    case setFlag(String, flag: UInt32, on: Bool)

    init(_ arguments: [String]) throws {
        if let reason = HelperRequests.refusal(arguments) { throw HelperFailure(reason) }
        let last = arguments.last!
        switch arguments[0] {
        case "/bin/mv": self = .move(arguments[arguments.count - 2], last, noReplace: arguments.count == 5)
        case "/bin/cp": self = .copy(arguments[arguments.count - 2], last, recursive: arguments.count == 5)
        case "/bin/ln": self = .link(arguments[3], last)
        case "/bin/mkdir": self = .mkdir(last)
        case "/bin/chmod": self = .chmod(last, mode_t(arguments[3], radix: 8)!)
        case "/bin/rm": self = .remove(last)
        case "/usr/sbin/chown":
            let owner = arguments[3].split(separator: ":")
            self = .chown(last, uid_t(owner[0])!, gid_t(owner[1])!)
        default:
            if arguments[1] == "-h", let (flag, on) = HelperRequests.settableFlag(arguments[2]) {
                self = .setFlag(last, flag: flag, on: on)
            } else {
                self = .unlock(last)
            }
        }
    }

    /// The paths it names, with what it does to each.
    var paths: [(path: String, role: HelperPathRole)] {
        switch self {
        case .move(let a, let b, _): return [(a, .remove), (b, .write)]
        case .copy(let a, let b, _): return [(a, .read), (b, .write)]
        case .link(_, let b), .mkdir(let b): return [(b, .write)]
        case .remove(let p): return [(p, .remove)]
        case .chmod(let p, _), .unlock(let p), .chown(let p, _, _), .setFlag(let p, _, _): return [(p, .change)]
        }
    }
}

struct HelperFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
    static func system(_ operation: String) -> HelperFailure {
        HelperFailure("\(operation): \(String(cString: strerror(errno))).")
    }
    static let changed = HelperFailure("The item or its folder changed during the request. Nothing new was overwritten.")
}

/// Per-execution test injection only: no process-global hook and no XPC way to install one.
struct HelperBoundary: Sendable {
    enum Phase: Sendable { case beforeParentOpen, afterParentOpen, afterLeafOpen, beforeCapture, afterCapture, beforePublish }
    let phase: Phase
    let path: String
}
