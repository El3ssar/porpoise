import Foundation
import PorpoiseCore

/// A transfer's shared text and actions; AppKit surfaces only render this snapshot.
public struct ActivityPresentation {
    public let title: String
    public let detailLine: String
    public let actions: [ActivityAction]
    public let fraction: Double
    public let hasFailures: Bool
    public let showsProgress: Bool
    public let isIndeterminate: Bool
    public let isPaused: Bool
    public var compactAction: ActivityAction? { actions.first { $0 == .failures } ?? actions.first { $0 == .pause || $0 == .resume || $0 == .retry } }

    public init(_ activity: Activity) {
        title = Self.title(of: activity)
        detailLine = (activity.state == .completed ? Self.summary(activity) : Self.status(of: activity))
            .replacingOccurrences(of: " — ", with: " · ")
        actions = Self.actions(for: activity)
        fraction = min(1, max(0, activity.fraction))
        hasFailures = activity.state == .failed || (activity.state == .completed && (!activity.errors.isEmpty || activity.verification?.ok == false))
        showsProgress = activity.state.isActive || activity.state == .queued
        isIndeterminate = activity.progress?.phase == .preparing || (activity.fraction <= 0 && activity.state.isActive) || activity.state == .queued
        isPaused = activity.state == .paused
    }

    public static func aggregateFraction(_ activities: [Activity]) -> Double {
        guard !activities.isEmpty else { return 1 }
        let total = activities.reduce(0.0) { $0 + Double($1.progress?.totalBytes ?? 0) }
        let fraction =
            total > 0
            ? activities.reduce(0.0) { $0 + Double($1.progress?.doneBytes ?? 0) } / total
            : activities.reduce(0.0) { $0 + $1.fraction } / Double(activities.count)
        return min(1, max(0, fraction))
    }

    public static func quotedRange(in title: String) -> NSRange? {
        guard let start = title.firstIndex(of: "“"), let end = title[start...].firstIndex(of: "”") else { return nil }
        return NSRange(start...end, in: title)
    }

    static func title(of a: Activity) -> String {
        let cloudTitle = a.cloudTitle, openingName = a.openingName, sources = a.sources, destination = a.destination, kind = a.kind
        if let cloudTitle { return cloudTitle }
        if let openingName { return "Opening “\(openingName)”" }
        let n = sources.count == 1 ? "“\(Activity.name(sources[0]))”" : FileFormat.itemCount(sources.count)
        if kind == .trash { return "Moving \(n) to the Trash" }
        let dest = destination.map { " to \(Activity.name($0))" } ?? ""
        return "\(kind.verb) \(n)\(dest)"
    }

    static func status(of a: Activity) -> String {
        let progress = a.progress, state = a.state, rate = a.rate, notice = a.notice, errors = a.errors
        let verification = a.verification, comparisonMethodTitle = a.comparisonMethodTitle
        let p = progress
        let amounts = p.map { $0.totalBytes > 0 ? "\(FileFormat.size($0.doneBytes)) of \(FileFormat.size($0.totalBytes))" : "" } ?? ""
        switch state {
        case .queued: return "Waiting for other operations to finish"
        case .paused: return ["Paused", amounts].filter { !$0.isEmpty }.joined(separator: " — ")
        case .waiting: return "Waiting for your answer"
        case .verifying: return "Verifying the copies…"
        case .running:
            if let p, p.phase == .preparing {
                return
                    "Preparing… \(FileFormat.count(p.totalFiles)) \(p.totalFiles == 1 ? "file" : "files") · \(FileFormat.count(p.totalFolders)) \(p.totalFolders == 1 ? "folder" : "folders") · \(FileFormat.size(p.totalBytes))"
            }
            var parts: [String] = []
            if let notice { parts.append(notice) }
            if let p, p.totalFiles > 0 {
                parts.append("\(FileFormat.count(p.doneFiles)) of \(FileFormat.count(p.totalFiles)) \(p.totalFiles == 1 ? "file" : "files")")
            }
            if !amounts.isEmpty { parts.append(amounts) }
            if notice == nil, rate.hasSpeedEstimate { parts.append(rate.speedText) }
            if notice == nil, let p, p.totalBytes > 0 || p.totalFiles > 0 { parts.append(rate.timeLeftText) }
            return parts.joined(separator: " — ")
        case .completed:
            let base = errors.isEmpty ? "Done" : "Done, with \(FileFormat.count(errors.count)) \(errors.count == 1 ? "error" : "errors")"
            var summary: [String] = []
            if let p, p.replacedItems > 0 { summary.append("Replaced \(FileFormat.count(p.replacedItems))") }
            if let p, p.skippedIdenticalItems > 0 {
                summary.append("Skipped \(FileFormat.count(p.skippedIdenticalItems)) identical (\(comparisonMethodTitle))")
            }
            return [([base] + summary).joined(separator: " · "), verification?.summary].compactMap { $0 }.joined(separator: ". ")
        case .failed: return errors.first ?? "Failed"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Interrupted: it can be resumed next time Porpoise starts"
        }
    }

    public static func summary(_ activity: Activity) -> String {
        // Opening a cloud file downloads it: nothing was copied anywhere the person chose.
        if activity.state == .completed, activity.openingName != nil, activity.errors.isEmpty {
            let bytes = activity.progress?.doneBytes ?? 0
            return bytes > 0 ? "Downloaded \(FileFormat.size(bytes))" : "Downloaded"
        }
        // What went, by name, as Finder says it.
        if activity.state == .completed, activity.errors.isEmpty, activity.kind == .trash || activity.kind == .delete, !activity.sources.isEmpty {
            let n = activity.sources.count
            let what = n == 1 ? "“\(Activity.name(activity.sources[0]))”" : FileFormat.itemCount(n)
            return activity.kind == .trash ? "Moved \(what) to the Trash" : "Deleted \(what)"
        }
        guard activity.state == .completed, activity.kind == .copy || activity.kind == .move,
            let progress = activity.progress
        else {
            return status(of: activity)
        }
        let count = progress.copiedItems
        var parts = [
            "\(activity.kind == .move ? "Moved" : "Copied") \(FileFormat.itemCount(count))"
                + (activity.destination.map { " to " + Activity.name($0) } ?? "")
        ]
        if !activity.errors.isEmpty {
            parts.append("\(FileFormat.count(activity.errors.count)) couldn’t be \(activity.kind == .move ? "moved" : "copied")")
        }
        if progress.replacedItems > 0 { parts.append("replaced \(FileFormat.count(progress.replacedItems))") }
        if progress.skippedIdenticalItems > 0 {
            parts.append("skipped \(FileFormat.count(progress.skippedIdenticalItems)) identical (\(activity.comparisonMethodTitle))")
        }
        return [parts.joined(separator: " · "), activity.verification?.summary].compactMap { $0 }.joined(separator: ". ")
    }

    private static func actions(for a: Activity) -> [ActivityAction] {
        let actions: [ActivityAction]
        switch a.state {
        case .queued: actions = [.earlier, .later, .cancel]
        case .running: actions = (a.canPause ? [.pause] : []) + [.cancel]
        case .paused: actions = [.resume, .cancel]
        case .waiting, .verifying: actions = [.cancel]
        case .failed: actions = [.failures, .retry]
        case .completed:
            actions =
                (a.errors.isEmpty ? [] : [.failures]) + (a.failedSources.isEmpty ? [] : [.retry])
                + (a.destination?.isFileURL == true ? [.reveal] : [])
        case .cancelled: actions = [.resume] + (a.destination?.isFileURL == true ? [.reveal] : [])
        case .interrupted: actions = a.destination?.isFileURL == true ? [.reveal] : []
        }
        return !a.errors.isEmpty && !actions.contains(.failures) ? [.failures] + actions : actions
    }
}

public enum ActivityAction: CaseIterable, Equatable, Sendable {
    case pause, resume, cancel, earlier, later, failures, retry, reveal
    public var symbol: String {
        switch self {
        case .pause: return "pause.fill"
        case .resume: return "play.fill"
        case .cancel: return "stop.fill"
        case .earlier: return "arrow.up"
        case .later: return "arrow.down"
        case .failures: return "exclamationmark.bubble"
        case .retry: return "arrow.clockwise"
        case .reveal: return "folder"
        }
    }
    public var help: String {
        switch self {
        case .pause: return "Pause (resumes from where it stopped)"
        case .resume: return "Resume"
        case .cancel: return "Stop"
        case .earlier: return "Start earlier"
        case .later: return "Start later"
        case .failures: return "Show failures"
        case .retry: return "Try the failed items again"
        case .reveal: return "Show the destination"
        }
    }
}

public enum EditActivityAction: CaseIterable, Equatable, Sendable {
    case keepBoth, openBoth, replace, send, show
    public func title(service: String) -> String {
        switch self {
        case .keepBoth: return "Keep Both"
        case .openBoth: return "Open Both"
        case .replace: return "Replace with Mine"
        case .send: return "Send Now"
        case .show: return "Show in Folder"
        }
    }
    public func help(service: String) -> String {
        switch self {
        case .keepBoth: return "Add your version next to \(service)’s as a separate file"
        case .openBoth: return "Open your version and \(service)’s side by side to compare them"
        case .replace: return "Make your version the current one; \(service)’s stays in the file’s version history"
        case .send: return "Try sending your saved changes to \(service) again"
        case .show: return "Show the file in its \(service) folder"
        }
    }
    public static func actions(for mark: CloudEditMark) -> [Self] {
        switch mark {
        case .conflict: return [.keepBoth, .openBoth, .replace]
        case .unsent: return [.send]
        default: return [.show]
        }
    }
}
