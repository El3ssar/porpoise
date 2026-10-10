import Foundation
import PorpoiseCore

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
        DispatchQueue.main.async { self.connections += 1; self.quit?.cancel() }
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

    func version(reply: @escaping (String) -> Void) { reply("5") }

    func checkFullDiskAccess(reply: @escaping (Bool) -> Void) {
        guard let uid = NSXPCConnection.current()?.effectiveUserIdentifier, let pw = getpwuid(uid) else { reply(false); return }
        // The Trash is one of the folders macOS keeps private without Full Disk Access.
        let trash = String(cString: pw.pointee.pw_dir) + "/.Trash"
        reply((try? FileManager.default.contentsOfDirectory(atPath: trash)) != nil)
    }

    func takeOwnership(ofTrashed path: String, reply: @escaping (String?) -> Void) {
        // Who asked: the user Porpoise runs as (its signature was checked when it connected).
        guard let uid = NSXPCConnection.current()?.effectiveUserIdentifier, uid != 0, let pw = getpwuid(uid) else {
            reply("Unknown user."); return
        }
        guard let command = HelperRequests.ownershipCommand(path: path, uid: uid, gid: pw.pointee.pw_gid,
                                                            home: String(cString: pw.pointee.pw_dir)) else {
            reply("Only items in your own Trash can be handed over."); return
        }
        // Built by the helper itself, so it isn't held to the app's list of tools.
        reply(HelperRequests.run(command))
    }

    func run(_ arguments: [String], reply: @escaping (String?) -> Void) {
        reply(HelperRequests.refusal(arguments) ?? HelperRequests.run(arguments))
    }
}

let helper = Helper()
let listener = NSXPCListener(machServiceName: PorpoiseHelperInfo.machService)
listener.delegate = helper
listener.resume()
helper.quitWhenIdle()
dispatchMain()
