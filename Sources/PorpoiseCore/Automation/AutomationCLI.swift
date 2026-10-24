import Foundation

public struct AutomationCLI: Sendable {
    public enum Output: Sendable { case lines, null, json }
    public var request: AutomationRequest
    public var output: Output = .lines

    public static let usage = """
        Usage: porpoise open FOLDER
               porpoise split FOLDER FOLDER
               porpoise reveal PATH [PATH …]
               porpoise selection [--null | --json]
               porpoise copy|move [--selection | PATH [PATH …]] --to FOLDER
        Talks only to the local running Porpoise app. Copy and move are queued in Activity.
        Use -- before a path that begins with a dash. Selection --null preserves newlines in names.
        """

    /// The caller supplies its working directory; parsing performs no filesystem IO.
    public static func parse(_ arguments: [String], directory: String) throws -> Self {
        guard let command = arguments.first, let action = AutomationRequest.Action(rawValue: command), action != .runTool else {
            throw AutomationError.invalidRequest
        }
        var paths: [String] = [], destination: String?, selection = false, literal = false
        var output: Output = .lines, outputSet = false
        let args = Array(arguments.dropFirst())
        var i = 0
        func absolute(_ path: String) -> String {
            URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardizedFileURL.path
        }
        while i < args.count {
            let arg = args[i]
            if !literal && arg == "--" {
                literal = true
            } else if !literal && arg == "--to" {
                guard action == .copy || action == .move, destination == nil, i + 1 < args.count else { throw AutomationError.invalidRequest }
                i += 1
                destination = absolute(args[i])
            } else if !literal && arg == "--selection" {
                guard action == .copy || action == .move, !selection else { throw AutomationError.invalidRequest }
                selection = true
            } else if !literal && (arg == "--null" || arg == "--json") {
                guard action == .selection, !outputSet else { throw AutomationError.invalidRequest }
                output = arg == "--null" ? .null : .json
                outputSet = true
            } else {
                guard literal || !arg.hasPrefix("-"), !arg.isEmpty, !arg.contains("\0") else { throw AutomationError.invalidRequest }
                paths.append(absolute(arg))
            }
            i += 1
        }
        let request = AutomationRequest(action: action, paths: paths, destination: destination, useSelection: selection)
        try request.validate()
        return Self(request: request, output: output)
    }
}
