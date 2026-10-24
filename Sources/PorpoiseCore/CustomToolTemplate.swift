import Foundation

/// Parses escapes and placeholders once; substituted values are never scanned as templates or code.
enum CustomToolTemplate {
    enum Part: Equatable {
        case literal(String)
        case placeholder(String)
    }
    static func parts(_ template: String) throws -> [Part] {
        var result: [Part] = [], literal = "", index = template.startIndex
        func flush() { if !literal.isEmpty { result.append(.literal(literal)); literal = "" } }
        while index < template.endIndex {
            let character = template[index], next = template.index(after: index)
            if character == "{" || character == "}" {
                if next < template.endIndex && template[next] == character {
                    literal.append(character); index = template.index(after: next); continue
                }
                guard character == "{", let close = template[next...].firstIndex(of: "}") else {
                    throw CustomToolError.invalid("Use {{ and }} for literal braces.")
                }
                let name = String(template[next..<close])
                guard ["selection", "folder", "otherFolder", "prompt"].contains(name) else {
                    throw CustomToolError.invalid("Unknown placeholder in arguments. Use {{ and }} for literal braces.")
                }
                flush(); result.append(.placeholder(name)); index = template.index(after: close)
            } else {
                literal.append(character); index = next
            }
        }
        flush(); return result
    }
    static func hasPlaceholder(_ parts: [Part]) -> Bool {
        parts.contains {
            if case .placeholder = $0 { return true }; return false
        }
    }

    /// Code options are not data arguments. Wrappers are deliberately refused when values are substituted: use the
    /// final executable directly so an option or wrapper cannot hide an interpreter from validation.
    static func validateCodeArguments(executable: String, arguments: [String], parsed: [[Part]], scanNested: Bool = true) throws {
        let name = (executable as NSString).lastPathComponent.lowercased()
        guard parsed.contains(where: hasPlaceholder) else { return }
        func reject() throws {
            throw CustomToolError.invalid(
                "Pass placeholders as data arguments to a script file, never as interpreter source. Use the executable directly.")
        }
        if ["env", "xcrun", "nice", "nohup", "command", "sudo", "doas", "arch", "time", "timeout", "busybox", "bun", "deno", "ssh"].contains(name) {
            try reject()
        }
        let shells = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"]
        func versioned(_ prefix: String) -> Bool {
            name.hasPrefix(prefix) && name.dropFirst(prefix.count).allSatisfy { $0.isNumber || $0 == "." || $0 == "t" || $0 == "m" }
        }
        let isPython = versioned("python") || versioned("pypy")
        var short: Set<Character> = [], long: Set<String> = []
        if shells.contains(name) { short = ["c"]; long = ["--command"] }
        if isPython { short = ["c"] }
        if versioned("perl") || versioned("ruby") { short = ["e", "E"] }
        if versioned("node") || name == "nodejs" { short = ["e", "p"]; long = ["--eval", "--print"] }
        if name == "osascript" || versioned("lua") || versioned("luajit") || versioned("tclsh") || ["swift", "julia", "rscript", "r"].contains(name) {
            short = ["e"]
        }
        if versioned("php") { short = ["r"] }
        if ["awk", "gawk", "mawk", "nawk"].contains(name) { short = ["e"]; long = ["--source"] }
        if ["pwsh", "powershell"].contains(name) { long = ["-command", "-encodedcommand", "-c", "-e"] }
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }
            let longName = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
            let evaluates =
                long.contains(longName)
                || (argument.hasPrefix("-") && !argument.hasPrefix("--") && argument.dropFirst().contains { short.contains($0) })
            if evaluates {
                if hasPlaceholder(parsed[index]) { try reject() }
                if !argument.contains("="), index + 1 < parsed.count, hasPlaceholder(parsed[index + 1]) { try reject() }
            }
            index += 1
        }
        for (offset, argument) in arguments.enumerated() where scanNested && offset + 1 < arguments.count {
            let nested = (argument as NSString).lastPathComponent.lowercased()
            let prefixes = ["python", "pypy", "perl", "ruby", "node", "php", "lua", "tclsh"]
            let known =
                shells.contains(nested)
                || ["osascript", "env", "xcrun", "awk", "gawk", "mawk", "nawk", "swift", "julia", "rscript", "pwsh", "powershell"].contains(nested)
                || prefixes.contains {
                    nested.hasPrefix($0) && nested.dropFirst($0.count).allSatisfy { $0.isNumber || $0 == "." || $0 == "t" || $0 == "m" }
                }
            if known {
                try validateCodeArguments(
                    executable: argument, arguments: Array(arguments.dropFirst(offset + 1)), parsed: Array(parsed.dropFirst(offset + 1)),
                    scanNested: false)
            }
        }
        if ["awk", "gawk", "mawk", "nawk"].contains(name) {
            var index = 0, scriptFile = false
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--" { index += 1; break }
                if ["-f", "--file"].contains(argument) { scriptFile = true; index += 2; continue }
                if argument.hasPrefix("-f") || argument.hasPrefix("--file=") { scriptFile = true; index += 1; continue }
                if ["-F", "-v", "--field-separator", "--assign"].contains(argument) { index += 2; continue }
                if argument.hasPrefix("-") { index += 1; continue }
                break
            }
            if !scriptFile, index < parsed.count, hasPlaceholder(parsed[index]) { try reject() }
        }
    }
}
