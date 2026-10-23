import PorpoiseFileSystem

// Compiled only into test and local builds (PORPOISE_TEST_HOOKS): a release has no debug bridge.
#if PORPOISE_TEST_HOOKS

import AppKit
import PorpoiseCore
import PorpoiseServices

extension DebugBridge {
    /// Transfer dialogs, the activity popover and their fixtures.
    static let transfersCommands: [String: Command] = [
        "drivefixture": DebugBridge.drivefixtureCommand,
        "dropboxfixture": DebugBridge.dropboxfixtureCommand,
        "reviewfront": DebugBridge.reviewfrontCommand,
        "transferdialog": DebugBridge.transferdialogCommand,
        "transferdialogcancel": DebugBridge.transferdialogcancelCommand,
        "transferstate": DebugBridge.transferstateCommand,
        "transfercopy": DebugBridge.transfercopyCommand,
        "transferpopover": DebugBridge.transferpopoverCommand,
        "activitypreview": DebugBridge.activitypreviewCommand,
        "activitycontrol": DebugBridge.activitycontrolCommand,
        "activitysize": DebugBridge.activitysizeCommand,
    ]

    /// Loopback-only visual fixture. Exercise real OAuth without opening the operator's browser.
    func drivefixtureCommand(_ arg: String) {
        guard Settings.isTesting, let raw = TestEnvironment.driveFake.value(),
            let fake = URL(string: raw), fake.scheme == "http", fake.host == "127.0.0.1"
        else { return }
        Task { @MainActor in
            do {
                let store = DriveAccountStore.shared
                let account: DriveAccount
                if let existing = store.accounts.first {
                    account = existing
                } else {
                    account = try await store.connect { url in Task { _ = try? await URLSession.shared.data(from: url) } }
                }
                self.wc?.view.setURL(DriveLocation(accountID: account.id).url)
                self.writeState(to: arg)
            } catch { try? error.localizedDescription.write(toFile: arg, atomically: true, encoding: .utf8) }
        }
    }

    /// Loopback-only Dropbox fixture, like `drivefixture`: signs in to PORPOISE_DROPBOX_FAKE and shows the account.
    func dropboxfixtureCommand(_ arg: String) {
        guard Settings.isTesting, TestEnvironment.dropboxFake.isSet else { return }
        Task { @MainActor in
            do {
                let store = DropboxAccountStore.shared
                let account: DropboxAccount
                if let existing = store.accounts.first {
                    account = existing
                } else {
                    account = try await store.connect { url in Task { _ = try? await URLSession.shared.data(from: url) } }
                }
                self.wc?.view.setURL(DropboxLocation(accountID: account.id).url)
                self.writeState(to: arg)
            } catch { try? error.localizedDescription.write(toFile: arg, atomically: true, encoding: .utf8) }
        }
    }

    func reviewfrontCommand(_ arg: String) {
        guard Settings.isTesting,
            let window = arg.isEmpty ? wc?.window : NSApp.windows.first(where: { $0.title.hasPrefix(arg) })
        else { return }
        NSApp.unhide(nil)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating
        window.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func transferdialogCommand(_ arg: String) {
        guard Settings.isTesting, let owner = wc?.window else { return }
        let folder = arg == "folder"
        let source = FileItem(
            url: URL(fileURLWithPath: "/tmp/Incoming/Report.pdf"), name: folder ? "Project" : "Report.pdf", isDirectory: folder,
            size: arg == "identical" ? 3_100_000 : 4_300_000,
            modificationDate: Date(timeIntervalSince1970: arg == "older" ? 1_700_000_000 : 1_700_100_000), contentType: "com.adobe.pdf")
        let target = FileItem(
            url: URL(fileURLWithPath: "/tmp/Backup/Report.pdf"), name: folder ? "Project" : "Report.pdf", isDirectory: folder,
            size: 3_100_000, modificationDate: Date(timeIntervalSince1970: arg == "identical" ? 1_700_100_000 : 1_700_050_000),
            contentType: "com.adobe.pdf")
        let job = FileJob(kind: .copy, sources: [source.url], destinationFolder: target.url.deletingLastPathComponent())
        transferPreviewJob = job
        let began = CACurrentMediaTime()
        FileOperationsController.shared.ui?.resolveConflict(
            ConflictInfo(
                source: source, destination: target, suggestedName: "Report 2.pdf", remainingConflicts: 42, differentItems: 30,
                identicalItems: 12,
                sourceFolder: folder ? TransferFolderSummary(itemCount: 13, bytes: 4_300_000) : nil,
                destinationFolder: folder ? TransferFolderSummary(itemCount: 14, bytes: 3_100_000) : nil
            ), kind: .copy, window: owner,
            job: job.control
        ) { _ in }
        try? String(format: "%.3f ms", (CACurrentMediaTime() - began) * 1000).write(
            toFile: NSTemporaryDirectory() + "porpoise-conflict-present.txt", atomically: true, encoding: .utf8)
    }

    func transferdialogcancelCommand(_ arg: String) {
        if let job = transferPreviewJob { FileOperationsController.shared.ui?.cancelConflict(for: job.control) }
        transferPreviewJob = nil
    }

    func transferstateCommand(_ arg: String) {
        guard Settings.isTesting else { return }
        let rows = FileOperationsController.shared.activities.map { activity -> [String: Any] in
            [
                "state": activity.state.rawValue, "phase": activity.progress?.phase.rawValue ?? "", "fraction": activity.fraction,
                "title": activity.title, "status": activity.statusText, "hasWindow": activity.originWindow != nil,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: arg))
        }
    }

    func transfercopyCommand(_ arg: String) {
        guard Settings.isTesting else { return }
        let paths = arg.components(separatedBy: "|")
        if paths.count == 2 {
            func location(_ path: String) -> URL { path.contains("://") ? URL(string: path)! : URL(fileURLWithPath: path) }
            FileOperationsController.shared.run(.copy, [location(paths[0])], to: location(paths[1]), window: wc?.window)
        }
    }

    func transferpopoverCommand(_ arg: String) {
        guard Settings.isTesting else { return }
        wc?.toolbar.transfers.showTransfers()
    }

    func activitypreviewCommand(_ arg: String) {
        activityPreview(arg)
    }

    func activitycontrolCommand(_ arg: String) {
        let controller = FileOperationsController.shared
        for activity in controller.activities where activity.state.isActive {
            switch arg {
            case "pause": controller.pause(activity)
            case "resume": controller.resume(activity)
            case "cancel": controller.cancel(activity)
            default: break
            }
        }
    }

    func activitysizeCommand(_ arg: String) {
        let size = arg.split(separator: " ").compactMap { Double($0) }
        if size.count == 2 { ActivityWindowController.shared.window?.setContentSize(NSSize(width: size[0], height: size[1])) }
    }

    /// Isolated visual-review fixture: real copy. Test bridge only.
    func activityPreview(_ path: String) {
        let root = URL(fileURLWithPath: path).appendingPathComponent("activity-" + UUID().uuidString)
        let source = root.appendingPathComponent("Project notes.txt")
        let destination = root.appendingPathComponent("Reports")
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data(repeating: 65, count: 2_100_000).write(to: source)
            let controller = FileOperationsController.shared
            controller.clearEnded()
            controller.concurrency = 2
            controller.run(.copy, [source], to: destination, window: nil)
            ActivityWindowController.shared.show()
        } catch {
            NSLog("Activity preview failed: %@", error.localizedDescription)
        }
    }
}

#endif
