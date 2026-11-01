import Foundation

/// Parsing is filesystem independent; paths retain symlink-sensitive components until the app resolves them.
public struct AutomationCLI: Sendable {
    public enum Output: Sendable { case lines, null, json }
    public var request: AutomationRequest
    public var output: Output = .lines
    public var timeout: TimeInterval?
    public var dryRun = false
    public var launch = false

    public static let commands = ["open", "split", "reveal", "selection", "pwd", "list", "status", "copy", "move"]
    public static let usage = """
        Usage: porpoise COMMAND [OPTIONS]
               porpoise PATH                         Open a folder or reveal a file

        Browse:     open FOLDER · split LEFT RIGHT · reveal PATH [PATH …]
        Inspect:    status · pwd · list · selection
        Transfer:   copy|move PATH [PATH …] --to FOLDER
                    copy|move --selection --to FOLDER

        Options:    --json           Machine-readable output (selection/pwd: path array)
                    --null           NUL-separated paths (selection/list/pwd)
                    --timeout SEC    Response deadline, 1–120 seconds
                    --launch         Start this tool's owning Porpoise app if needed
                    --dry-run        Describe a copy/move without submitting it
                    --help, -h       Show help; also works after any command
                    --version        Show the installed tool version

        Examples:   porpoise open "$HOME/Documents"
                    porpoise list --json
                    porpoise copy --selection --to ./Archive --dry-run
                    porpoise selection --null | xargs -0 -I{} printf '%s\\n' '{}'

        Enable command-line control in Porpoise Settings → Advanced first.
        Copy/move return when queued for approval in Activity, not when bytes finish copying.
        Quote paths containing spaces. Put -- before a path beginning with -.
        Shell setup: porpoise completions bash|zsh|fish prints an optional completion script.
        Run porpoise help COMMAND for details; help --json describes every command. No command changes shell or privacy settings.
        """

    public static func help(for command: String) -> String? {
        let syntax: String
        let detail: String
        let example: String
        switch command {
        case "open":
            syntax = "open FOLDER"; detail = "Open an existing local folder in a new tab. Relative paths use your working directory."
            example = "porpoise open \"$HOME/Documents\" --launch"
        case "split":
            syntax = "split LEFT RIGHT"; detail = "Open two existing local folders side by side in a new tab."
            example = "porpoise split ./Source ./Destination"
        case "reveal":
            syntax = "reveal PATH [PATH …]"; detail = "Select local items in their containing folders (at most 20 folders)."
            example = "porpoise reveal -- \"./report final.pdf\" ./-notes.txt"
        case "selection":
            syntax = "selection [--json | --null]";
            detail = "Print selected paths from the active pane. Remote items are URLs. Use --null or --json for names containing newlines."
            example = "porpoise selection --json"
        case "pwd", "location":
            syntax = "pwd [--json | --null]"; detail = "Print the active pane's location, including remote URLs. Alias: location."
            example = "porpoise pwd"
        case "list", "ls":
            syntax = "list [--limit COUNT] [--offset COUNT] [--json | --null]"
            detail =
                "Print paths from the active pane's current displayed rows, in display order. This uses the loaded view, including its filter/search; it does not launch a separate filesystem scan. Default limit: 100; maximum: 10000. Alias: ls."
            example = "porpoise list --limit 50 --offset 50 --json"
        case "status":
            syntax = "status [--json]";
            detail = "Show the connected app's location, displayed/selected counts, windows and tabs. A failure explains how to connect."
            example = "porpoise status --json"
        case "copy", "move":
            syntax = "\(command) [--selection | PATH [PATH …]] --to FOLDER [--dry-run]"
            detail =
                "Queue a \(command) in Activity. Porpoise asks for approval before starting and never uses administrator access. Success means queued, not completed. --selection uses a captured active-pane selection; explicit paths are local. --dry-run submits nothing; selected paths are read only to describe the plan. After a timeout, check Activity before retrying."
            example = "porpoise \(command) \"./report final.pdf\" --to ../Archive --dry-run"
        default: return nil
        }
        return
            "Usage: porpoise \(syntax)\n\n\(detail)\n\nExample: \(example)\n\nCommon options: --json, --timeout SECONDS, --launch, --help\nUse -- before literal paths beginning with -. For transfers put --to FOLDER before --."
    }

    /// Output only. The CLI never modifies shell startup files or evaluates completion scripts.
    public static func completions(for shell: String) -> String? {
        let names = commands.joined(separator: " ") + " help completions"
        switch shell {
        case "bash":
            return """
                _porpoise_complete() {
                  if [[ $COMP_CWORD -eq 1 ]]; then
                    COMPREPLY=( $(compgen -W '\(names)' -- "${COMP_WORDS[COMP_CWORD]}") )
                  else
                    COMPREPLY=()
                    while IFS= read -r candidate; do COMPREPLY+=("$candidate"); done < <(compgen -f -- "${COMP_WORDS[COMP_CWORD]}")
                  fi
                }
                complete -F _porpoise_complete porpoise
                """
        case "zsh":
            return """
                #compdef porpoise
                _porpoise() {
                  if (( CURRENT == 2 )); then
                    _values 'command' \(names)
                  else
                    _files
                  fi
                }
                compdef _porpoise porpoise
                """
        case "fish":
            return "complete -c porpoise -n '__fish_use_subcommand' -a '\(names)'"
        default: return nil
        }
    }

    public struct UsageError: Error, LocalizedError, Sendable {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public static func parse(_ arguments: [String], directory: String) throws -> Self {
        guard let command = arguments.first else { throw UsageError(message: "Choose a command. Run porpoise --help for examples.") }
        let aliases = ["pwd": "location", "ls": "list"]
        guard let action = AutomationRequest.Action(rawValue: aliases[command] ?? command), action != .runTool else {
            throw UsageError(message: "Unknown command \(AutomationDisplay.quotedPath(command)). Run porpoise --help to list commands.")
        }
        var paths: [String] = [], destination: String?, selection = false, literal = false
        var output: Output = .lines, outputSet = false, timeout: TimeInterval?, dryRun = false, launch = false
        var limit: Int?, offset: Int?
        let args = Array(arguments.dropFirst())
        var i = 0
        func fail(_ message: String) -> UsageError { UsageError(message: message + " Run porpoise help \(command) for usage.") }
        func absolute(_ path: String) -> String {
            path.hasPrefix("/") ? path : (directory.hasSuffix("/") ? directory : directory + "/") + path
        }
        func value(after option: String) throws -> String {
            guard i + 1 < args.count, !args[i + 1].isEmpty, !args[i + 1].contains("\0") else { throw fail("\(option) needs a value.") }
            i += 1
            return args[i]
        }
        while i < args.count {
            let arg = args[i]
            if !literal && arg == "--" {
                literal = true
            } else if !literal && arg == "--to" {
                guard action == .copy || action == .move, destination == nil else { throw fail("--to is accepted once, only for copy or move.") }
                destination = absolute(try value(after: arg))
            } else if !literal && arg == "--selection" {
                guard action == .copy || action == .move, !selection else { throw fail("--selection is accepted once, only for copy or move.") }
                selection = true
            } else if !literal && (arg == "--null" || arg == "--json") {
                guard !outputSet else { throw fail("Choose only one output format: --json or --null.") }
                guard arg != "--null" || [.selection, .location, .list].contains(action) else {
                    throw fail("--null is available for selection, pwd and list.")
                }
                output = arg == "--null" ? .null : .json
                outputSet = true
            } else if !literal && arg == "--timeout" {
                guard timeout == nil, let seconds = Double(try value(after: arg)), seconds.isFinite, (1...120).contains(seconds) else {
                    throw fail("--timeout must be a number from 1 to 120 seconds.")
                }
                timeout = seconds
            } else if !literal && arg == "--launch" {
                guard !launch else { throw fail("--launch was supplied twice.") }; launch = true
            } else if !literal && arg == "--dry-run" {
                guard [.copy, .move].contains(action), !dryRun else { throw fail("--dry-run is available once for copy or move.") }
                dryRun = true
            } else if !literal && (arg == "--limit" || arg == "--offset") {
                guard action == .list, let count = Int(try value(after: arg)), count >= 0,
                    arg == "--offset" || (1...10_000).contains(count)
                else { throw fail("list needs --limit 1–10000 and a nonnegative --offset.") }
                if arg == "--limit" {
                    guard limit == nil else { throw fail("--limit was supplied twice.") }; limit = count
                } else {
                    guard offset == nil else { throw fail("--offset was supplied twice.") }; offset = count
                }
            } else {
                guard literal || !arg.hasPrefix("-"), !arg.isEmpty, !arg.contains("\0") else {
                    throw fail("Unknown option \(AutomationDisplay.quotedPath(arg)). Put -- before a filename beginning with -.")
                }
                paths.append(absolute(arg))
            }
            i += 1
        }
        let request = AutomationRequest(action: action, paths: paths, destination: destination, useSelection: selection, limit: limit, offset: offset)
        do { try request.validate() } catch {
            throw fail("Invalid operands for \(command). Check the number of paths, destination and --selection.")
        }
        return Self(request: request, output: output, timeout: timeout, dryRun: dryRun, launch: launch)
    }
}
