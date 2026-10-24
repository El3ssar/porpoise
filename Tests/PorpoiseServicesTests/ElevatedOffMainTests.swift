import Foundation
import PorpoiseCore
import PorpoiseFileSystem
import PorpoiseServicesTestSupport
import PorpoiseTestSupport
import Testing

@testable import PorpoiseServices

/// What runs as administrator after a file operation runs off the main thread, as its own Activity (W-236, W-235 #11).
@Suite(.serialized, .isolatedSettings) @MainActor struct ElevatedOffMainTests {
    @Test func theAdministratorPartRunsOffTheMainThreadAsAnActivity() async throws {
        let s = try Scratch()
        let item = try s.file("locked.txt", "x")
        let entered = Flag(), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let real = FileOperationsController.elevate
        FileOperationsController.elevate = { _, _, _ in
            #expect(!Thread.isMainThread)
            // A regression onto the main thread must fail without blocking the test's own controller.
            guard !Thread.isMainThread else { return .done }
            entered.set()
            #expect(release.wait(timeout: .now() + eventualTimeout) == .success)
            return .done
        }
        defer { FileOperationsController.elevate = real }
        let ui = ScriptedUI()
        ui.authenticates = true
        let c = makeController(ui)
        var result: Bool?
        c.authorize(verb: "delete", items: [item], commands: [["/bin/rm", "--", item.path]], kind: .delete, window: nil) { result = $0 }
        try #require(await eventually { entered.isSet })
        let activity = try #require(c.activities.last)
        #expect(result == nil && !activity.state.isEnded && activity.kind == .delete)
        release.signal()
        #expect(await eventually { result == true && activity.state == .completed })
        // The waiting form (single-item actions) still waits.
        let synchronous = Flag()
        FileOperationsController.elevate = { _, _, _ in
            synchronous.set()
            return .done
        }
        #expect(c.authorize(verb: "delete", items: [item], commands: [["/bin/rm", "--", item.path]], window: nil))
        #expect(synchronous.isSet)
    }

    @Test func failuresAndCancellingEndTheActivity() async throws {
        let s = try Scratch()
        let item = try s.file("locked.txt", "x")
        let real = FileOperationsController.elevate
        defer { FileOperationsController.elevate = real }
        let ui = ScriptedUI()
        ui.authenticates = true
        let c = makeController(ui)
        FileOperationsController.elevate = { _, _, _ in .failed("Operation not permitted") }
        var result: Bool?
        c.authorize(verb: "copy", items: [item], commands: [["/bin/cp"]], kind: .copy, window: nil) { result = $0 }
        #expect(await eventually { result == false })
        #expect(c.activities.last?.state == .failed && ui.authorizationErrors == ["Operation not permitted"])
        FileOperationsController.elevate = { _, _, _ in .cancelled }
        result = nil
        c.authorize(verb: "copy", items: [item], commands: [["/bin/cp"]], kind: .copy, window: nil) { result = $0 }
        #expect(await eventually { result == false })
        #expect(c.activities.last?.state == .cancelled && ui.authorizationErrors.count == 1)
        // Declined at the question: nothing runs, no Activity.
        ui.authenticates = false
        let count = c.activities.count
        c.authorize(verb: "copy", items: [item], commands: [["/bin/cp"]], kind: .copy, window: nil) { result = $0 }
        #expect(result == false && c.activities.count == count)
    }

    @Test func osascriptErrorsReadAsTheirMessage() {
        #expect(FileOperationsController.osascriptMessage("0:120: execution error: cp: /x: Permission denied (1)\n") == "cp: /x: Permission denied")
        #expect(FileOperationsController.osascriptMessage("") == "The operation failed.")
    }
}
