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
        default: self = .unlock(last)
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
