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

    /// The connecting process's audit token. NSXPCConnection has it but doesn't publish it: if it's ever gone, every
    /// connection is refused (Porpoise then says to update it), never accepted on a process number instead.
    private static func auditToken(_ c: NSXPCConnection) -> Data? {
        guard c.responds(to: NSSelectorFromString("auditToken")), let value = c.value(forKey: "auditToken") as? NSValue else { return nil }
        var token = audit_token_t()
        value.getValue(&token, size: MemoryLayout<audit_token_t>.size)
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // XPC checks the running process; its bundle on disk must be intact too (see CodeSigning.isIntact).
        guard let req = clientRequirement, CodeSigning.accepts(auditToken: Self.auditToken(c), requirement: req) else { return false }
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

    func version(reply: @escaping (String) -> Void) { reply(PorpoiseHelperInfo.version) }

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

    func perform(_ requests: [[String]], authorization: Data, handOver: [String], reply: @escaping (Bool, String?) -> Void) {
        let (uid, refusal) = caller()
        if let refusal { reply(false, refusal); return }
        guard uid != 0, let pw = getpwuid(uid) else { reply(false, "Unknown user."); return }
        let r = HelperRequests.perform(
            requests, authorization: authorization, handOver: handOver, caller: uid, group: pw.pointee.pw_gid,
            home: String(cString: pw.pointee.pw_dir), authorizer: SystemAuthorizer(), policy: .live(caller: uid))
        reply(r.cancelled, r.message)
    }
}

let helper = Helper()
let listener = NSXPCListener(machServiceName: PorpoiseHelperInfo.machService)
listener.delegate = helper
listener.resume()
helper.quitWhenIdle()
dispatchMain()
