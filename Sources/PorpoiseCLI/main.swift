import Darwin
import Foundation
import PorpoiseCore
import PorpoiseServices

var requestedJSON = false

/// Local-only commands never launch the app or open an automation socket.
func writeError(_ message: String) { FileHandle.standardError.write(Data(("porpoise: " + message + "\n").utf8)) }
func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value); data.append(10)
    FileHandle.standardOutput.write(data)
}
func writePaths(_ paths: [String], output: AutomationCLI.Output) throws {
    if output == .json { try writeJSON(paths); return }
    let separator = output == .null ? "\0" : "\n"
    if !paths.isEmpty { FileHandle.standardOutput.write(Data((paths.joined(separator: separator) + separator).utf8)) }
}

/// Resolve the CLI's executable symlink to its own app, never a differently registered copy.
func owningApplication() -> URL? {
    var size: UInt32 = 4096
    var path = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&path, &size) != 0 {
        path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0 else { return nil }
    }
    let executable = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
    let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard app.pathExtension == "app", Bundle(url: app)?.bundleIdentifier == "app.porpoise.Porpoise" else { return nil }
    return app
}
func version() -> String {
    owningApplication().flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? "development"
}

func launchOwningApplication(deadline: Date) throws {
    guard let app = owningApplication() else {
        throw AutomationCLI.UsageError(message: "--launch needs the tool bundled inside Porpoise.app. Install it from Porpoise Settings → Advanced.")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", "-a", app.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    while process.isRunning && deadline > Date() { Thread.sleep(forTimeInterval: 0.02) }
    if process.isRunning {
        // Only the /usr/bin/open child created above; never signal an existing Porpoise instance.
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        throw CLIStartupError()
    }
    guard process.terminationStatus == 0 else { throw AutomationError.unavailable }
}

func send(_ request: AutomationRequest, invocation: AutomationCLI) throws -> AutomationResponse {
    guard invocation.launch else { return try AutomationSocket.send(request, timeout: invocation.timeout) }
    let deadline = Date().addingTimeInterval(min(invocation.timeout ?? 10, 10))
    try launchOwningApplication(deadline: deadline)
    // Read-only readiness probes can retry. A mutation is submitted exactly once after readiness succeeds.
    while true {
        do {
            _ = try AutomationSocket.send(AutomationRequest(action: .status), timeout: min(1, max(0.1, deadline.timeIntervalSinceNow)))
            break
        } catch AutomationError.unavailable {
            guard deadline > Date() else { throw AutomationError.unavailable }
            Thread.sleep(forTimeInterval: 0.1)
        } catch AutomationError.timedOut {
            guard deadline > Date() else { throw CLIStartupError() }
            // Read-only status can time out while the browser is opening. Never retry the actual request.
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    return try AutomationSocket.send(request, timeout: invocation.timeout)
}

struct TransferPreview: Encodable {
    let action: String
    let sources: [String]
    let destination: String
    let submitted = false
    let requiresApproval = true
}

func run() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let literalStart = arguments.firstIndex(of: "--") ?? arguments.count
    requestedJSON = arguments[..<literalStart].contains("--json")
    if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] || arguments == ["help"] {
        print(AutomationCLI.usage); return
    }
    if arguments.first == "completions" {
        guard arguments.count == 2, let script = AutomationCLI.completions(for: arguments[1]) else {
            throw AutomationCLI.UsageError(message: "Use porpoise completions bash, zsh or fish. Output is a script; no shell settings are changed.")
        }
        print(script); return
    }
    if arguments == ["--version"] || arguments == ["version"] { print("porpoise \(version())"); return }
    if arguments == ["help", "--json"] {
        struct Command: Encodable { let name: String; let help: String; let readOnly: Bool }
        try writeJSON(
            AutomationCLI.commands.map {
                Command(name: $0, help: AutomationCLI.help(for: $0)!, readOnly: ["status", "pwd", "list", "selection"].contains($0))
            })
        return
    }
    if arguments.first == "help" {
        guard arguments.count == 2, let help = AutomationCLI.help(for: arguments[1]) else {
            throw AutomationCLI.UsageError(message: "Choose a known command for help. Run porpoise --help to list commands.")
        }
        print(help); return
    }
    let optionEnd = arguments.firstIndex(of: "--") ?? arguments.count
    if arguments[..<optionEnd].contains("--help") || arguments[..<optionEnd].contains("-h") {
        guard let command = arguments.first, let help = AutomationCLI.help(for: command) else {
            throw AutomationCLI.UsageError(message: "Unknown command. Run porpoise --help to list commands.")
        }
        print(help); return
    }
    if let first = arguments.first, !AutomationCLI.commands.contains(first), !["location", "ls"].contains(first), !first.hasPrefix("-") {
        // Familiar `porpoise .` / `porpoise file.pdf` shorthand. Unknown words still get a useful typo error.
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: first, isDirectory: &directory) {
            var operands = 1, index = 1, literal = false
            while index < arguments.count {
                let value = arguments[index]
                if !literal && value == "--" {
                    literal = true
                } else if !literal && value == "--timeout" {
                    index += 1
                } else if literal || !value.hasPrefix("-") {
                    operands += 1
                }
                index += 1
            }
            arguments.insert(directory.boolValue && operands == 1 ? "open" : "reveal", at: 0)
        }
    }
    let invocation = try AutomationCLI.parse(arguments, directory: FileManager.default.currentDirectoryPath)
    requestedJSON = invocation.output == .json
    if invocation.dryRun {
        var paths = invocation.request.paths
        if invocation.request.useSelection {
            let response = try send(AutomationRequest(action: .selection), invocation: invocation)
            if let error = response.error { throw CLIResponseError(message: error) }
            paths = response.paths
            guard !paths.isEmpty else {
                throw AutomationCLI.UsageError(message: "Nothing is selected. Select files in Porpoise or supply source paths.")
            }
        }
        let preview = TransferPreview(action: invocation.request.action.rawValue, sources: paths, destination: invocation.request.destination!)
        if invocation.output == .json {
            try writeJSON(preview)
        } else {
            print(
                "Dry run: \(preview.action) \(paths.count) item\(paths.count == 1 ? "" : "s") to \(AutomationDisplay.quotedPath(preview.destination))"
            )
            for path in paths { print("  \(AutomationDisplay.quotedPath(path))") }
            print("Nothing submitted. Running without --dry-run queues an approval request in Activity.")
        }
        return
    }
    let response = try send(invocation.request, invocation: invocation)
    if let error = response.error { throw CLIResponseError(message: error) }
    switch invocation.request.action {
    case .selection, .location:
        try writePaths(response.paths, output: invocation.output)
    case .list:
        if invocation.output == .json { try writeJSON(response) } else { try writePaths(response.paths, output: invocation.output) }
    case .status:
        if invocation.output == .json {
            try writeJSON(response)
        } else if let context = response.context {
            print("Porpoise is connected.")
            print("Location: \(context.location.map(AutomationDisplay.quotedPath) ?? "No browser window")")
            print(
                "\(context.windows) windows · \(context.tabs) tabs · \(context.displayedItems) displayed · \(context.selectedItems) selected\(context.loading ? " · loading" : "")"
            )
        } else {
            throw AutomationError.invalidResponse
        }
    default:
        if invocation.output == .json { try writeJSON(response) } else if let message = response.message { print(message) }
    }
}

struct CLIStartupError: Error, LocalizedError {
    var errorDescription: String? {
        "Starting Porpoise timed out before any request was submitted. Start the app manually, then retry without --launch."
    }
}

struct CLIResponseError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

do { try run() } catch {
    let code: Int32
    let message: String
    if error is AutomationCLI.UsageError {
        code = 2; message = error.localizedDescription
    } else if error is CLIStartupError {
        code = 4; message = error.localizedDescription
    } else if let automation = error as? AutomationError {
        switch automation {
        case .unavailable, .busy:
            code = 3
            message =
                "Cannot connect to Porpoise. Start the app, enable Allow command-line control in Settings → Advanced, then retry. Use --launch to start this tool’s owning app."
        case .timedOut: code = 4; message = automation.localizedDescription
        case .unsafeEndpoint:
            code = 5;
            message =
                "The local automation endpoint has unsafe ownership or permissions. Quit Porpoise and restart it; do not relax endpoint permissions."
        case .invalidResponse:
            code = 5;
            message = "The app and CLI could not exchange a valid response. Reinstall the tool from this app’s Settings → Advanced and retry."
        case .invalidRequest, .oversized: code = 2; message = automation.localizedDescription
        }
    } else {
        code = 1; message = error.localizedDescription
    }
    if requestedJSON {
        struct ErrorDetails: Encodable { let code: String; let message: String }
        struct ErrorResult: Encodable { let ok = false; let error: ErrorDetails }
        let category = [1: "refused", 2: "usage", 3: "unavailable", 4: "timeout", 5: "protocol"][Int(code)] ?? "error"
        try? writeJSON(ErrorResult(error: ErrorDetails(code: category, message: message)))
    } else {
        writeError(message)
    }
    exit(code)
}
