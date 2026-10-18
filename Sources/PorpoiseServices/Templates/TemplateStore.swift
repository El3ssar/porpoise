import Foundation
import PorpoiseCore
import PorpoiseFileSystem

/// Each personal template is a portable JSON file; file names are IDs, never user-provided paths.
public final class TemplateStore {
    private struct Archive: Codable { var version = 1; var template: FileTemplate }
    public static let shared = TemplateStore()
    public let directory: URL
    public init(directory: URL? = nil) {
        self.directory =
            directory
            ?? (Settings.isTesting ? TestEnvironment.templateDir.value().map { URL(fileURLWithPath: $0) } : nil)
            ?? Settings.supportFolder.appendingPathComponent("Templates", isDirectory: true)
    }
    public func prepare() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    public func personal() throws -> [FileTemplate] {
        try prepare()
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { try? Self.decode($0) }.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }
    public func save(_ template: FileTemplate) throws {
        try Self.validate(template); try prepare()
        try JSONEncoder().encode(template).write(to: directory.appendingPathComponent(template.id.uuidString + ".json"), options: .atomic)
    }
    @discardableResult public func importTemplate(_ url: URL) throws -> FileTemplate {
        let data = try Self.read(url)
        let template: FileTemplate
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let isArchive = object?["template"] != nil && object?["version"] != nil
        let isRecord = ["id", "title", "filename", "contents"].allSatisfy { object?[$0] != nil }
        if url.pathExtension.lowercased() == "json", isArchive || isRecord {
            let decoded = try Self.decode(data)
            // Importing never silently replaces an existing personal template.
            template = FileTemplate(title: decoded.title, filename: decoded.filename, contents: decoded.contents)
        } else {
            template = FileTemplate(title: url.deletingPathExtension().lastPathComponent, filename: url.lastPathComponent, contents: data)
        }
        try save(template); return template
    }
    public func export(_ template: FileTemplate, to url: URL) throws {
        try Self.validate(template)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Archive(template: template)).write(to: url, options: .atomic)
    }
    private static func read(_ url: URL) throws -> Data {
        try RegularFileData.read(url, limit: 16 * 1024 * 1024)
    }
    private static func decode(_ url: URL) throws -> FileTemplate {
        try decode(read(url))
    }
    private static func decode(_ data: Data) throws -> FileTemplate {
        let result: FileTemplate
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["template"] != nil, object["version"] != nil {
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1 else { throw FileOperationError.failed("This template archive version is not supported.") }
            result = archive.template
        } else {
            result = try JSONDecoder().decode(FileTemplate.self, from: data)
        }
        try validate(result); return result
    }
    private static func validate(_ template: FileTemplate) throws {
        guard !template.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            template.title.utf8.count <= 512, template.filename.utf8.count <= 4096, template.contents.count <= 8 * 1024 * 1024
        else { throw FileOperationError.failed("The template is empty or too large.") }
        _ = try TemplateExpansion.render(template, context: TemplateContext(name: template.title))
    }
    /// Find a free counter without overwriting another file. The eventual create is also exclusive.
    public func preview(_ template: FileTemplate, pattern: String, folder: URL, context: TemplateContext) throws -> (
        name: String, contents: Data, counter: Int
    ) {
        let existing = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        var context = context
        for offset in 0..<10000 {
            let (counter, overflow) = max(1, context.counter).addingReportingOverflow(offset)
            if overflow { break }
            context.counter = counter
            let rendered = try TemplateExpansion.render(template, filenamePattern: pattern, context: context)
            if !existing.contains(rendered.name) { return (rendered.name, rendered.contents, counter) }
            if !pattern.contains("{counter") { throw FileOperationError.failed("A file named “\(rendered.name)” already exists.") }
        }
        throw FileOperationError.failed("No unused template counter was found.")
    }
    public func create(_ template: FileTemplate, pattern: String, folder: URL, context: TemplateContext) throws -> URL {
        let result = try preview(template, pattern: pattern, folder: folder, context: context)
        return try FileActions.makeFile(named: result.name, in: folder, contents: result.contents)
    }
}
