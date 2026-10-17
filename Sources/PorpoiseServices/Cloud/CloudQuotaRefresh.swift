import Foundation

public enum CloudAccountRefreshPolicy {
    public static let interval: TimeInterval = 45
}

/// Foreground account details follow the same cadence across providers, independently of file-change longpolls.
@MainActor final class CloudQuotaRefresh {
    private var task: Task<Void, Never>?
    private let interval: TimeInterval
    private let refresh: @MainActor () -> Void
    init(interval: TimeInterval = CloudAccountRefreshPolicy.interval, refresh: @escaping @MainActor () -> Void) {
        self.interval = interval; self.refresh = refresh
    }
    deinit { task?.cancel() }
    func setActive(_ active: Bool) {
        task?.cancel(); task = nil
        guard active else { return }
        refresh()
        let interval = interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }
}
