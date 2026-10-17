import Foundation
import PorpoiseCore

/// Offline copies with no store and no network, for test instances (PORPOISE_OFFLINE_DEMO) and tests: states are set
/// by hand, and the commands change them the way the engine would, at once.
public final class DemoOfflineService: CloudOfflineService {
    /// Per item: what Properties and the menus see, and the badge (folders default to no badge, files to cloud-only).
    public var details: [URL: CloudOfflineDetails] = [:]
    public var states: [URL: CloudState] = [:]
    public var folders: Set<URL> = []
    /// Rows that can't have offline copies (Shared with me…).
    public var unsupported: Set<URL> = []
    public var denials: [URL: String] = [:]
    /// What `plan` answers (nil: 1 MB per item); `planError` fails it; `holdsPlans` waits for `answerPlan`.
    public var nextPlan: CloudKeepPlan?
    public var planError: Error?
    public var holdsPlans = false
    private var heldPlan: (() -> Void)?
    /// Items Remove Download refuses, with the message.
    public var refusals: [URL: String] = [:]
    public var usages: [String: CloudOfflineUsage] = [:]
    public var cacheLimit: Int64? = 5 << 30
    public var root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Porpoise/Cloud")
    /// Commands asked for, in order ("download a, b", "keep a", "stop a", "remove a", "plan a", "removeRecent id").
    public private(set) var log: [String] = []

    public init() {}

    public func supports(_ url: URL) -> Bool { !url.isFileURL && !unsupported.contains(url) }

    public func state(for url: URL) -> CloudState {
        if let s = states[url] { return s }
        let d = details(for: url)
        if d.kept || d.inheritedFrom != nil { return .kept }
        return d.downloaded || folders.contains(url) ? .local : .cloudOnly
    }

    public func keepDenial(for url: URL) -> String? { denials[url] }

    public func details(for url: URL) -> CloudOfflineDetails { details[url] ?? CloudOfflineDetails() }

    private func names(_ urls: [URL]) -> String { urls.map(\.lastPathComponent).joined(separator: ", ") }

    private func changed(_ urls: [URL]) {
        NotificationCenter.default.post(name: CloudOfflineHub.changed, object: nil, userInfo: ["urls": urls])
    }

    private func update(_ urls: [URL], _ change: (inout CloudOfflineDetails) -> Void) {
        for u in urls {
            var d = details(for: u)
            change(&d)
            details[u] = d
            states[u] = nil
        }
        changed(urls)
    }

    public func downloadNow(_ urls: [URL]) {
        log.append("download " + names(urls))
        update(urls) { $0.downloaded = true }
    }

    public func plan(keep urls: [URL], done: @escaping (Result<CloudKeepPlan, Error>) -> Void) -> () -> Void {
        log.append("plan " + names(urls))
        let answer = { [self] in
            if let planError { return done(.failure(planError)) }
            done(.success(nextPlan ?? CloudKeepPlan(bytes: Int64(urls.count) << 20, items: urls.count, available: 100 << 30, fits: true)))
        }
        if holdsPlans { heldPlan = answer } else { answer() }
        return { [weak self] in self?.heldPlan = nil }
    }

    public func answerPlan() {
        let a = heldPlan
        heldPlan = nil
        a?()
    }

    public func keep(_ urls: [URL]) {
        log.append("keep " + names(urls))
        update(urls) {
            $0.kept = true
            $0.downloaded = true
        }
    }

    public func stopKeeping(_ urls: [URL]) {
        log.append("stop " + names(urls))
        update(urls) { $0.kept = false }
    }

    public func removeDownload(_ urls: [URL]) -> [String] {
        log.append("remove " + names(urls))
        let refused = urls.compactMap { refusals[$0] }
        update(urls.filter { refusals[$0] == nil }) {
            $0.kept = false
            $0.downloaded = false
            $0.bytes = 0
        }
        return refused
    }

    public func usage(account: String) -> CloudOfflineUsage { usages[account] ?? CloudOfflineUsage() }

    public func removeRecent(account: String) {
        log.append("removeRecent " + account)
        usages[account]?.recent = 0
        changed([])
    }

    /// `kept`, `inherited:<folder>`, `downloaded`, `cloudonly`, `local`, `downloading:<0…1>`, `uploading:<0…1>`,
    /// `error:<reason>` (the test bridge's words).
    public func set(_ url: URL, _ word: String) {
        let parts = word.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        var d = CloudOfflineDetails()
        states[url] = nil
        switch parts.first {
        case "kept": d.kept = true; d.downloaded = true
        case "inherited": d.inheritedFrom = arg; d.downloaded = true
        case "downloaded", "local": d.downloaded = true
        case "downloading": states[url] = .downloading(Double(arg)); d.progress = Double(arg)
        case "uploading": states[url] = .uploading(Double(arg))
        case "error": states[url] = .error(arg); d.error = arg
        default: break
        }
        details[url] = d
        changed([url])
    }
}
