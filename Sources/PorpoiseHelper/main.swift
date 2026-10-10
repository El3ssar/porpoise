import Foundation
import PorpoiseCore

/// Runs as root under launchd. Does single file operations for Porpoise (see PorpoiseHelperProtocol). It runs only
/// while needed: launchd starts it when Porpoise connects, and it quits as soon as Porpoise is done.
final class Helper: NSObject, NSXPCListenerDelegate, PorpoiseHelperProtocol {
    /// Only Porpoise, signed with the helper's own certificate, may connect.
    private let clientRequirement = CodeSigning.requirement(identifier: PorpoiseHelperInfo.appIdentifier)
    /// Open connections (only touched on the main queue).
    private var connections = 0

    /// Started without a request to answer (launchd only starts it for one, so this is a safety net): quit soon.
    func quitIfUnused() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in if self?.connections == 0 { exit(0) } }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        guard let req = clientRequirement else { return false }
        c.setCodeSigningRequirement(req)
        c.exportedInterface = NSXPCInterface(with: PorpoiseHelperProtocol.self)
        c.exportedObject = self
        DispatchQueue.main.async { self.connections += 1 }
        c.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connections -= 1
                // Porpoise is done: quit now; launchd starts the helper again for the next request.
                if self.connections == 0 { exit(0) }
            }
        }
        c.resume()
        return true
    }

    func version(reply: @escaping (String) -> Void) { reply("2") }

    func takeOwnership(ofTrashed path: String, reply: @escaping (String?) -> Void) {
        // Who asked: the user Porpoise runs as (its signature was checked when it connected).
        guard let uid = NSXPCConnection.current()?.effectiveUserIdentifier, uid != 0, let pw = getpwuid(uid) else {
            reply("Unknown user."); return
        }
        let gid = pw.pointee.pw_gid
        let home = String(cString: pw.pointee.pw_dir)
        // The item must sit directly in that user's Trash, and not be a symlink (chown would change its target).
        let item = URL(fileURLWithPath: path)
        let parent = item.deletingLastPathComponent().resolvingSymlinksInPath().path
        let homeTrash = URL(fileURLWithPath: home).appendingPathComponent(".Trash").resolvingSymlinksInPath().path
        var st = stat()
        guard PorpoiseHelperInfo.isInUsersTrash(path: path, resolvedParent: parent, uid: uid, resolvedHomeTrash: homeTrash),
              lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else {
            reply("Only items in your own Trash can be handed over."); return
        }
        // -P (the default with -R): symlinks inside are changed themselves, never followed.
        run(["/usr/sbin/chown", "-R", "-P", "\(uid):\(gid)", item.resolvingSymlinksInPath().path], allowing: true, reply: reply)
    }

    func run(_ arguments: [String], reply: @escaping (String?) -> Void) { run(arguments, allowing: false, reply: reply) }

    /// `allowing`: a command built by the helper itself (takeOwnership), not one sent by the app.
    private func run(_ arguments: [String], allowing: Bool, reply: @escaping (String?) -> Void) {
        guard let tool = arguments.first, allowing || PorpoiseHelperInfo.allowedTools.contains(tool) else {
            reply("Porpoise's helper doesn't run \(arguments.first ?? "nothing")."); return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = Array(arguments.dropFirst())
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { reply(error.localizedDescription); return }
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        reply(p.terminationStatus == 0 ? nil : (msg.isEmpty ? "\(tool) failed." : msg.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

let helper = Helper()
let listener = NSXPCListener(machServiceName: PorpoiseHelperInfo.machService)
listener.delegate = helper
listener.resume()
helper.quitIfUnused()
dispatchMain()
