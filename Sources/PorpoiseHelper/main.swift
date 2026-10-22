import Foundation
import PorpoiseHelperKit

/// Runs as root under launchd. Does single file operations for Porpoise (see PorpoiseHelperProtocol). It runs only
/// while needed: launchd starts it when Porpoise connects, and it quits as soon as Porpoise is done.
final class Helper: NSObject, NSXPCListenerDelegate, PorpoiseHelperProtocol {
    /// Only Porpoise, signed with the helper's own certificate, may connect.
    private let clientRequirement = CodeSigning.requirement(identifier: PorpoiseHelperInfo.appIdentifier)
    /// Open connections (only touched on the main queue).
    private var connections = 0
    private var quit: DispatchWorkItem?
    /// Idle time before quitting. Quitting right after a request loses the next one: launchd waits before it starts
    /// a job that just exited, and a request arriving while the helper is exiting is dropped. One action (check, then
    /// run) and quick successive ones go to the same, already running helper.
    private static let idleTime: TimeInterval = 10

    /// Quits once no connection has been open for `idleTime` (launchd starts it again on the next request).
    func quitWhenIdle() {
        quit?.cancel()
        let w = DispatchWorkItem { [weak self] in if self?.connections == 0 { exit(0) } }
        quit = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleTime, execute: w)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // XPC checks the running process; its bundle on disk must be intact too (see CodeSigning.isIntact).
        guard let req = clientRequirement, CodeSigning.isIntact(pid: c.processIdentifier, requirement: req) else { return false }
        c.setCodeSigningRequirement(req)
        c.exportedInterface = NSXPCInterface(with: PorpoiseHelperProtocol.self)
        c.exportedObject = self
        // Counted before accepting (sync): a quit already queued on main would otherwise run first, see no
        // connection, and exit with this one's request unanswered.
        let opened = {
            self.connections += 1; self.quit?.cancel()
        }
        if Thread.isMainThread { opened() } else { DispatchQueue.main.sync(execute: opened) }
        c.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connections -= 1
                if self.connections == 0 { self.quitWhenIdle() }
            }
        }
        c.resume()
        return true
    }

    func version(reply: @escaping (String) -> Void) { reply("6") }

    /// The user who asked (Porpoise runs as them; its signature was checked when it connected), if they may use the
    /// helper: administrators only. Checked on every request, so a user removed from admin is refused at once.
    private func caller() -> (uid: uid_t, refusal: String?) {
        guard let uid = NSXPCConnection.current()?.effectiveUserIdentifier else { return (0, "Unknown user.") }
        return (uid, PorpoiseHelperInfo.callerRefusal(uid))
    }

    func checkFullDiskAccess(reply: @escaping (Bool) -> Void) {
        let (uid, refusal) = caller()
        guard refusal == nil, let pw = getpwuid(uid) else { reply(false); return }
        // The Trash is one of the folders macOS keeps private without Full Disk Access.
        let trash = String(cString: pw.pointee.pw_dir) + "/.Trash"
        reply((try? FileManager.default.contentsOfDirectory(atPath: trash)) != nil)
    }

    func takeOwnership(ofTrashed path: String, reply: @escaping (String?) -> Void) {
        let (uid, refusal) = caller()
        if let refusal { reply(refusal); return }
        guard uid != 0, let pw = getpwuid(uid) else { reply("Unknown user."); return }
        // Done in-process, through file descriptors: a chown of a path could be redirected by the user meanwhile.
        reply(HelperRequests.takeOwnership(path: path, uid: uid, gid: pw.pointee.pw_gid, home: String(cString: pw.pointee.pw_dir)))
    }

    func run(_ arguments: [String], reply: @escaping (String?) -> Void) {
        reply(caller().refusal ?? HelperRequests.run(arguments))
    }
}

let helper = Helper()
let listener = NSXPCListener(machServiceName: PorpoiseHelperInfo.machService)
listener.delegate = helper
listener.resume()
helper.quitWhenIdle()
dispatchMain()
