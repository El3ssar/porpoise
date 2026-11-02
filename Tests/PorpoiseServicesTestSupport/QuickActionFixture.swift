import Foundation

public enum QuickActionFixture {
    @discardableResult public static func make(
        in directory: URL, name: String = "Record", titles: [String: String]? = nil,
        types: [String] = ["public.item"], application: String? = "com.apple.finder", script: String = ":", iconName: String = "NSActionTemplate"
    ) throws -> URL {
        let workflow = directory.appendingPathComponent(name + ".workflow", isDirectory: true)
        let contents = workflow.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var service: [String: Any] = [
            "NSMenuItem": titles ?? ["default": name], "NSMessage": "runWorkflowAsService", "NSSendFileTypes": types, "NSIconName": iconName,
        ]
        service["NSRequiredContext"] = application.map { ["NSApplicationIdentifier": $0] } ?? [:]
        try write(["NSServices": [service]], to: contents.appendingPathComponent("Info.plist"))
        let action: [String: Any] = [
            "AMAccepts": ["Container": "List", "Optional": true, "Types": ["com.apple.cocoa.string"]],
            "AMProvides": ["Container": "List", "Types": ["com.apple.cocoa.string"]],
            "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
            "ActionName": "Run Shell Script", "BundleIdentifier": "com.apple.RunShellScript",
            "Class Name": "RunShellScriptAction", "AMActionVersion": "2.0.3",
            "UUID": UUID().uuidString, "InputUUID": UUID().uuidString, "OutputUUID": UUID().uuidString,
            "ActionParameters": ["COMMAND_STRING": script, "inputMethod": 1, "shell": "/bin/zsh", "source": ""],
        ]
        let metadata: [String: Any] = [
            "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
            "inputTypeIdentifier": "com.apple.Automator.fileSystemObject",
            "outputTypeIdentifier": "com.apple.Automator.nothing",
        ]
        try write(
            ["AMDocumentVersion": "2", "actions": [["action": action]], "connectors": [], "workflowMetaData": metadata],
            to: contents.appendingPathComponent("document.wflow"))
        return workflow
    }

    public static func recordScript(to url: URL) -> String {
        "printf '%s\\0' \"$@\" > '" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func write(_ value: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url)
    }
}
