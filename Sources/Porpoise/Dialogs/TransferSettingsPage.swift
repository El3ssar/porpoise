import AppKit
import PorpoiseServices

enum TransferSettingsPage {
    static func build(_ f: FormBuilder) {
        let s = Settings.shared
        f.section("Copies and moves")
        f.stepper("Run at a time:", s.jobsConcurrency, 1...8, suffix: "jobs") { FileOperationsController.shared.concurrency = $0 }
        f.check("Verify copies with SHA-256", s.verifyCopies) { s.verifyCopies = $0 }
        f.section("Transfer rules")
        f.stepper("Bandwidth per job:", s.transferMBPerSecond, 0...100_000, suffix: "MB/s (0 is unlimited)") { s.transferMBPerSecond = $0 }
        f.stepper("Connection retries:", s.transferRetries, 0...10, suffix: "retries") { s.transferRetries = $0 }
        f.stepper("Initial retry delay:", Int(s.transferBackoffSeconds), 1...30, suffix: "seconds") { s.transferBackoffSeconds = Double($0) }
        f.note(
            "Retry delays double up to 30 seconds. Only reads and transfers into temporary staging are retried automatically. History records retries and exclusions."
        )
        f.text("Excluded globs (one per ;):", s.transferExclusions) { s.transferExclusions = $0 }
        f.note(
            "For example: *.tmp;.git;project/build/*. Name patterns apply at every depth. Patterns with / start at the selected item's parent; * can span folders. Excluded move sources stay in place."
        )
        f.note(
            "Rules apply to new jobs. Bandwidth is shared by a job's parallel workers. Jobs wait during sleep; remote jobs also wait while the network is unavailable. Your own Pause stays in effect after wake or reconnect."
        )
    }
}
