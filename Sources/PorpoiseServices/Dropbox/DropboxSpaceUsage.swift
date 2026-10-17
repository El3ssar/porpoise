import Foundation

/// Used and allocated bytes must describe the same pool: personal account or shared team space.
public struct DropboxSpaceUsage: Decodable, Equatable, Sendable {
    public let used: Int64?
    public let total: Int64?
    private enum Keys: String, CodingKey { case used, allocation, tag = ".tag", allocated }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        let personalUsed = try values.decode(UInt64.self, forKey: .used)
        let allocation = try values.nestedContainer(keyedBy: Keys.self, forKey: .allocation)
        switch try allocation.decode(String.self, forKey: .tag) {
        case "individual":
            used = Int64(exactly: personalUsed)
            total = Int64(exactly: try allocation.decode(UInt64.self, forKey: .allocated))
        case "team":
            used = Int64(exactly: try allocation.decode(UInt64.self, forKey: .used))
            total = Int64(exactly: try allocation.decode(UInt64.self, forKey: .allocated))
        default:
            used = Int64(exactly: personalUsed); total = nil
        }
    }
}
extension DropboxClient {
    public func spaceUsage() async throws -> DropboxSpaceUsage { try await rpc("users/get_space_usage", NSNull()) }
}
