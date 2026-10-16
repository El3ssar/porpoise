import Foundation

public enum SyncNoticeEvent: Sendable {
    case conflicts(Int)
    case failure(reason: String, waiting: Int?)
    case deletionReview(count: Int, destination: String)
}

/// The same quiet notification payload is used in production and isolated review dumps.
public struct SyncNotificationPayload: Codable, Equatable, Sendable {
    public let title: String
    public let body: String
    public let action: String
    public let categoryIdentifier: String
    public let threadIdentifier: String
    public let pairID: UUID
    public init(pair: SavedSync, event: SyncNoticeEvent) {
        pairID = pair.id; threadIdentifier = pair.id.uuidString
        switch event {
        case .conflicts(let count):
            title = pair.description + " needs you"
            body = "\(count) \(count == 1 ? "file" : "files") changed on both sides."
            action = "Review"
        case .failure(let reason, let waiting):
            title = "Couldn’t sync " + pair.name
            let message = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = waiting.map { " \($0) \($0 == 1 ? "item is" : "items are") waiting." } ?? ""
            body = message + (message.hasSuffix(".") || message.isEmpty ? "" : ".") + suffix
            action = "Show"
        case .deletionReview(let count, let destination):
            title = "Sync paused"
            body = "\(count) \(count == 1 ? "item would" : "items would") be moved to the Trash in \(destination)."
            action = "Review"
        }
        categoryIdentifier = action == "Show" ? "PORPOISE_SYNC_SHOW" : "PORPOISE_SYNC_REVIEW"
    }
}
