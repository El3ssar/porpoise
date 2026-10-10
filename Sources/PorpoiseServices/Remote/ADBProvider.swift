import Foundation
import PorpoiseCore

/// Android over adb. `adb shell` runs its argument with the device's sh, so paths are single-quoted.
final class ADBProvider: RemoteProvider {
    let serial: String
    private var model: String?
    /// Printed by our rename script when the target exists (older adb doesn't pass exit codes on).
    private static let existsMarker = "__PORPOISE_EXISTS__"

    init(serial: String) { self.serial = serial }

    static var adbPath: String? { AndroidTools.adbPath }

    static func devices(timeout: TimeInterval = 0) -> [(serial: String, model: String)] {
        guard let adb = adbPath else { return [] }
        AndroidTools.willUseServer()
        guard let r = try? Shell.run(adb, ["devices", "-l"], timeout: timeout) else { return [] }
        return RemoteParsing.parseADBDevices(String(decoding: r.out, as: UTF8.self))
    }

    /// Cached, also when the phone isn't listed: breadcrumbs ask for it on the main thread on every redraw.
    func rootTitle(_ url: URL) -> String {
        if let m = model { return m }
        let m = Self.devices(timeout: 3).first(where: { $0.serial == serial })?.model ?? serial
        model = m
        return m
    }

    private func adb(_ args: [String]) throws -> Data {
        guard let adb = Self.adbPath else {
            throw RemoteError.unsupported("Android support needs adb. Install it with: brew install android-platform-tools — then enable USB debugging on the phone.")
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

    func rename(_ remote: URL, to newName: String) throws {
        try RemoteFS.checkName(newName)
        let dst = q(remote.deletingLastPathComponent().appendingPathComponent(newName))
        let out = try shell("if [ -e \(dst) ]; then echo \(Self.existsMarker); else mv \(q(remote)) \(dst); fi")
        if out.contains(Self.existsMarker) { throw RemoteError.exists(newName) }
    }

    func move(_ remote: [URL], into folder: URL) throws {
        try shell("mv " + remote.map(q).joined(separator: " ") + " " + q(folder) + "/")
    }

    func copy(_ remote: [URL], into folder: URL) throws {
        try shell("cp -r " + remote.map(q).joined(separator: " ") + " " + q(folder) + "/")
    }
}
