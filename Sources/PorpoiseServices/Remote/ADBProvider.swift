import Foundation
import PorpoiseCore

/// Android over adb. `adb shell` runs its argument with the device's sh, so paths are single-quoted.
final class ADBProvider: RemoteProvider, RemoteTransferTargetChecking {
    let serial: String
    /// The phone's name once adb gave it (read on any thread: breadcrumbs ask on the main one).
    private var model: String? {
        get { modelLock.withLock { _model } }
        set { modelLock.withLock { _model = newValue } }
    }
    private var _model: String?
    private let modelLock = NSLock()
    /// When the name was last asked of adb (it's asked again after a while if it wasn't known then).
    private var askedAt: Date?
    /// Printed by our rename script when the target exists (older adb doesn't pass exit codes on).
    private static let existsMarker = "__PORPOISE_EXISTS__"

    /// adb is looked up on every use (it may be installed while Porpoise runs); tests pass their own.
    private let tool: String?
    private var adbPath: String? { tool ?? Self.adbPath }

    init(serial: String, adb: String? = nil) {
        self.serial = serial
        tool = adb
    }

    static var adbPath: String? { AndroidTools.adbPath }

    static func devices(timeout: TimeInterval = 0, adb: String? = nil) -> [(serial: String, model: String)] {
        guard let adb = adb ?? adbPath else { return [] }
        AndroidTools.willUseServer()
        guard let r = try? Shell.run(adb, ["devices", "-l"], timeout: timeout) else { return [] }
        return RemoteParsing.parseADBDevices(String(decoding: r.out, as: UTF8.self))
    }

    /// How long the phone's name may take to come from adb.
    var titleTimeout: TimeInterval = 3
    /// How long before asking adb again for a name it didn't give.
    static let titleRetry: TimeInterval = 10

    /// The phone's name; its serial number until adb has given it. Breadcrumbs ask on the main thread on every redraw:
    /// adb is asked on another one, and `RemoteFS.titlesChanged` is posted once the name is there.
    func rootTitle(_ url: URL) -> String {
        if let m = model { return m }
        let due = modelLock.withLock {
            guard askedAt.map({ Date().timeIntervalSince($0) > Self.titleRetry }) ?? true else { return false }
            askedAt = Date()
            return true
        }
        if due {
            let timeout = titleTimeout, tool = tool, serial = serial
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let m = Self.devices(timeout: timeout, adb: tool).first(where: { $0.serial == serial })?.model else { return }
                self?.model = m
                DispatchQueue.main.async { NotificationCenter.default.post(name: RemoteFS.titlesChanged, object: nil) }
            }
        }
        return serial
    }

    private func adb(_ args: [String]) throws -> Data {
        guard let adb = adbPath else {
            throw RemoteError.unsupported(
                "Android support needs adb. Install it with: brew install android-platform-tools — then enable USB debugging on the phone.")
        }
        AndroidTools.willUseServer()
        let r = try Shell.run(adb, ["-s", serial] + args)
        if r.status != 0 { throw RemoteError.failed(r.err.isEmpty ? "adb failed (\(r.status))" : r.err) }
        return r.out
    }

    @discardableResult
    private func shell(_ script: String) throws -> String { String(decoding: try adb(["shell", script]), as: UTF8.self) }

    /// The device root maps to shared storage.
    private func path(_ url: URL) -> String { url.path.isEmpty || url.path == "/" ? "/sdcard" : url.path }
    private func q(_ url: URL) -> String { RemoteParsing.quote(path(url)) }

    func list(_ folder: URL) throws -> [FileItem] {
        let out = try shell("ls -la \(RemoteParsing.quote(path(folder) + "/"))")
        if out.contains("Permission denied") && out.split(separator: "\n").count < 2 { throw RemoteError.failed("Permission denied") }
        var base = URLComponents(url: folder, resolvingAgainstBaseURL: false)
        if folder.path.isEmpty || folder.path == "/" { base?.path = "/sdcard/" }
        let dir = base?.url ?? folder
        return RemoteParsing.parseLsLong(out, folder: dir.appendingPathComponent("", isDirectory: true))
    }

    func download(_ remote: URL, into localFolder: URL) throws -> URL {
        try RemoteFS.downloadStaged(remote.lastPathComponent, into: localFolder) { staging in
            _ = try adb(["pull", path(remote), staging.path])
        }
    }

    func upload(_ local: URL, into remoteFolder: URL) throws { _ = try adb(["push", local.path, path(remoteFolder) + "/"]) }

    func delete(_ remote: [URL]) throws {
        if let top = remote.first(where: { ["/", "/sdcard", "/sdcard/"].contains(path($0)) }) {
            throw RemoteError.failed("“\(path(top))” is a top folder and can't be deleted.")
        }
        try shell("rm -rf " + remote.map(q).joined(separator: " "))
    }

    func makeFolder(_ remote: URL) throws { try shell("mkdir -p \(q(remote))") }

    func removeEmptyFolder(_ remote: URL) throws { try shell("rmdir \(q(remote))") }

    func rename(_ remote: URL, to newName: String) throws {
        try RemoteFS.checkName(newName)
        let dst = q(remote.deletingLastPathComponent().appendingPathComponent(newName))
        let out = try shell("if [ -e \(dst) ]; then echo \(Self.existsMarker); else mv \(q(remote)) \(dst); fi")
        if out.contains(Self.existsMarker) { throw RemoteError.exists(newName) }
    }

    func transferTargetExists(_ target: URL) throws -> Bool {
        let parent = q(target.deletingLastPathComponent()), target = q(target)
        let output = try shell(
            "if [ -d \(parent) ] && [ -r \(parent) ] && [ -x \(parent) ]; then "
                + "if [ -e \(target) ] || [ -L \(target) ]; then printf yes; else printf no; fi; fi")
        guard output == "yes" || output == "no" else { throw RemoteError.failed("Could not check the destination folder.") }
        return output == "yes"
    }

    func move(_ remote: [URL], into folder: URL) throws {
        try relocate(remote, into: folder, command: "mv")
    }

    func copy(_ remote: [URL], into folder: URL) throws {
        try relocate(remote, into: folder, command: "cp -r")
    }
    private func relocate(_ remote: [URL], into folder: URL, command: String) throws {
        for source in remote {
            let target = q(folder.appendingPathComponent(source.lastPathComponent))
            let result = try shell(
                "if [ -e \(target) ] || [ -L \(target) ]; then echo \(Self.existsMarker); else \(command) \(q(source)) \(q(folder))/; fi")
            if result.contains(Self.existsMarker) { throw RemoteError.exists(source.lastPathComponent) }
        }
    }

}
