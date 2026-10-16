import Foundation
import PorpoiseCore

/// Missing linked folders are empty, incomplete browse surfaces. They can never authorize a sync plan.
/// Permission, connection and cancellation errors remain errors, rather than suggesting files were deleted.
public enum CompareBrowserScan {
    public static func scan(_ root: URL, options: SyncCompareOptions, maxDepth: Int? = nil, cancellation: DiskCancellation) throws -> SyncSnapshot {
        do { return try SyncScanner.scan(root, options: options, maxDepth: maxDepth, cancellation: cancellation) } catch let error as POSIXError
            where root.isFileURL && error.code == .ENOENT
        {
            try cancellation.check()
            return SyncSnapshot(entries: [], complete: false)
        }
    }
}
