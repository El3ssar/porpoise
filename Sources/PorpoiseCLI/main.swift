import Foundation
import PorpoiseCore
import PorpoiseServices

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
    print(AutomationCLI.usage)
} else {
    do {
        let invocation = try AutomationCLI.parse(arguments, directory: FileManager.default.currentDirectoryPath)
        let response = try AutomationSocket.send(invocation.request)
        if let error = response.error {
            FileHandle.standardError.write(Data((error + "\n").utf8))
            exit(1)
        }
        if invocation.request.action == .selection {
            switch invocation.output {
            case .json:
                var data = try JSONEncoder().encode(response.paths)
                data.append(10)
                FileHandle.standardOutput.write(data)
            case .lines, .null:
                let separator = invocation.output == .null ? "\0" : "\n"
                if !response.paths.isEmpty {
                    FileHandle.standardOutput.write(Data((response.paths.joined(separator: separator) + separator).utf8))
                }
            }
        } else if let message = response.message {
            print(message)
        }
    } catch {
        let hint = (error as? AutomationError) == .invalidRequest ? " Run porpoise --help for usage." : ""
        FileHandle.standardError.write(Data((error.localizedDescription + hint + "\n").utf8))
        exit(1)
    }
}
