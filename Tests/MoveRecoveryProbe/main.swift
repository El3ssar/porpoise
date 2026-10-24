import Darwin
import Foundation
import PorpoiseFileSystem
import PorpoiseServices

// Test-only process-death probe. The caller creates an isolated fixture with these exact children.
guard CommandLine.arguments.count == 3 else { exit(64) }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
guard root.lastPathComponent.hasPrefix("porpoise-test-") else { exit(64) }
let mode = CommandLine.arguments[2]
let journal = TransferStageJournal(folder: root.appendingPathComponent("journal"))
var deletions = 0
let receipt = try LocalMoveRemovalReceipt(
    source: root.appendingPathComponent("source"),
    onCheckpoint: { checkpoint in
        try journal.checkpoint(checkpoint)
        if case .claimed(_, _, _, true) = checkpoint, mode == "verified" { kill(getpid(), SIGKILL) }
        if case .claimed(_, _, _, false) = checkpoint, mode == "claimed",
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("source").path)
        {
            kill(getpid(), SIGKILL)
        }
        if case .deleting = checkpoint {
            deletions += 1
            if mode == "deleting", deletions == 2 { kill(getpid(), SIGKILL) }
        }
    })
try receipt.removeSource(afterVerifying: root.appendingPathComponent("target"))
exit(1)  // Every selected checkpoint must kill the process before completion.
