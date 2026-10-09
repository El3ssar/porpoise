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

    func version(reply: @escaping (String) -> Void) { reply("1") }

    func run(_ arguments: [String], reply: @escaping (String?) -> Void) {
        guard let tool = arguments.first, PorpoiseHelperInfo.allowedTools.contains(tool) else {
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
