import Foundation

extension DropboxClient {
    /// The item a share link points to, when this account can see it; nil when it can't (or the link is gone).
    public func sharedLink(_ link: URL) async throws -> DropboxItem? {
        struct Linked: Decodable { var id: String? }
        let linked: Linked
        do {
            linked = try await rpc("sharing/get_shared_link_metadata", ["url": link.absoluteString])
        } catch DropboxError.notFound {
            return nil
        } catch DropboxError.api(409, _) {
            return nil  // access denied, or not a link to anything
        }
        // Only the account's own id names something it can open; the metadata read also proves it can.
        guard let id = linked.id, !id.isEmpty else { return nil }
        do { return try await metadata(id) } catch DropboxError.notFound { return nil } catch DropboxError.api(409, _) { return nil }
    }
}
