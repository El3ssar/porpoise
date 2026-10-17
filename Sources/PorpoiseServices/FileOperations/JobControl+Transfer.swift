import Foundation
import PorpoiseCore

extension JobControl {
    func asTransferControl(onBytes: @escaping (Int64) -> Void, onStatus: @escaping (String?) -> Void) -> Shell.TransferControl {
        Shell.TransferControl(
            isPaused: { self.isPaused }, isCancelled: { self.isCancelled }, isInterrupted: { self.isInterrupted },
            onBytes: onBytes, onStatus: onStatus)
    }
}
