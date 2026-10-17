import Foundation

public struct FileTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var filename: String
    public var contents: Data
    public init(id: UUID = UUID(), title: String, filename: String, contents: Data) {
        self.id = id; self.title = title; self.filename = filename; self.contents = contents
    }
    public var textContents: String? { contents.contains(0) ? nil : String(data: contents, encoding: .utf8) }
    public static let builtins = [
        FileTemplate(id: UUID(uuidString: "53D8CE40-7C9D-4C79-871B-C38B5BB15001")!, title: "Text File", filename: "Text File.txt", contents: Data()),
        FileTemplate(
            id: UUID(uuidString: "53D8CE40-7C9D-4C79-871B-C38B5BB15002")!, title: "HTML File", filename: "HTML File.html",
            contents: Data(
                "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<title>{name}</title>\n</head>\n<body>\n</body>\n</html>\n".utf8)),
        FileTemplate(
            id: UUID(uuidString: "53D8CE40-7C9D-4C79-871B-C38B5BB15003")!, title: "Dated Note", filename: "{date}-Note-{counter:03}.md",
            contents: Data("# {name}\n\nCreated {date} at {time} by {user}.\n".utf8)),
    ]
}

public struct TemplateContext: Sendable {
    public var date: Date
    public var user: String
    public var name: String
    public var counter: Int
    public var timeZone: TimeZone
    public init(date: Date = Date(), user: String = NSUserName(), name: String, counter: Int = 1, timeZone: TimeZone = .current) {
        self.date = date; self.user = user; self.name = name; self.counter = counter; self.timeZone = timeZone
    }
}

public enum TemplateExpansion {
    /// Only known placeholders are expanded. Ordinary JSON, CSS and unknown braces remain literal.
    public static func expand(_ text: String, context: TemplateContext) -> String {
        let regex = try! NSRegularExpression(pattern: #"\{(date|time|user|name|counter(?::0?[1-9])?)\}"#)
        let input = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: input.length)).reversed() {
            let token = input.substring(with: match.range(at: 1))
            let value: String
            switch token {
            case "name": value = context.name
            case "user": value = context.user
            case "date", "time":
                value = FileFormat.posixString(context.date, format: token == "date" ? "yyyy-MM-dd" : "HH-mm-ss", timeZone: context.timeZone)
            default:
                let width = token.split(separator: ":").last.flatMap { Int($0) } ?? 0
                let number = String(max(1, context.counter))
                value = String(repeating: "0", count: max(0, min(9, width) - number.count)) + number
            }
            if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: value) }
        }
        return result
    }
    public static func render(_ template: FileTemplate, filenamePattern: String? = nil, context: TemplateContext) throws -> (
        name: String, contents: Data
    ) {
        let name = expand(filenamePattern ?? template.filename, context: context)
        guard FileActions.isValidName(name) else { throw FileOperationError.failed("The template produces an invalid file name.") }
        var bodyContext = context; bodyContext.name = (name as NSString).deletingPathExtension
        let contents = template.textContents.map { Data(expand($0, context: bodyContext).utf8) } ?? template.contents
        return (name, contents)
    }
}
