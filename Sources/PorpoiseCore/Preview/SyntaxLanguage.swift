import Foundation

/// Lexical highlighting, not a compiler grammar. Detection never opens a file or invokes a tool.
public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case plain, swift, c, cpp, objectiveC, python, javascript, typescript, json, yaml, toml
    case html, xml, css, shell, go, rust, java, kotlin, ruby, markdown, sql, lua, diff

    public static func detect(filename: String, prefix: String = "") -> SyntaxLanguage? {
        let name = (filename as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        let extensions: [String: SyntaxLanguage] = [
            "swift": .swift, "c": .c, "h": .c, "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp,
            "m": .objectiveC, "mm": .objectiveC, "py": .python, "pyw": .python, "js": .javascript, "jsx": .javascript,
            "mjs": .javascript, "cjs": .javascript, "ts": .typescript, "tsx": .typescript, "json": .json, "jsonc": .json,
            "yaml": .yaml, "yml": .yaml, "toml": .toml, "html": .html, "htm": .html, "xml": .xml, "svg": .xml,
            "plist": .xml, "xhtml": .html, "css": .css, "scss": .css, "sh": .shell, "bash": .shell, "zsh": .shell,
            "fish": .shell, "go": .go, "rs": .rust, "java": .java, "kt": .kotlin, "kts": .kotlin, "rb": .ruby,
            "md": .markdown, "markdown": .markdown, "sql": .sql, "lua": .lua,
            "diff": .diff, "patch": .diff,
        ]
        if let language = extensions[ext] { return language }
        if ["gemfile", "rakefile"].contains(name) { return .ruby }
        if [".bashrc", ".bash_profile", ".profile", ".zshrc", ".zprofile"].contains(name) { return .shell }
        if name == "readme" || name == "changelog" { return .markdown }
        let first = String(prefix.prefix(256)).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if first.hasPrefix("#!") {
            let words = first.lowercased().split { $0.isWhitespace || $0 == "/" }
            if words.contains(where: { $0.hasPrefix("python") }) { return .python }
            if words.contains("ruby") { return .ruby }
            if words.contains(where: { ["sh", "bash", "zsh", "fish", "dash"].contains(String($0)) }) { return .shell }
            if words.contains("node") || words.contains("nodejs") { return .javascript }
            if words.contains("lua") { return .lua }
        }
        return ["txt", "text", "log", "csv", "tsv", "conf", "ini"].contains(ext) ? .plain : nil
    }
}
