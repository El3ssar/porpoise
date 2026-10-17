import Foundation

/// Reading a cloud service's listing page by page.
public enum CloudPager {
    /// Calls `page` with each page's token, from `first`, until it returns none. Cancellation is checked before every
    /// page, and a token seen twice (a service going round in circles) throws `repeated`.
    public static func each<Token: Hashable>(from first: Token? = nil, repeated: Error, _ page: (Token?) async throws -> Token?) async throws {
        var token = first
        var seen: Set<Token> = []
        repeat {
            try Task.checkCancellation()
            token = try await page(token)
            if let token, !seen.insert(token).inserted { throw repeated }
        } while token != nil
    }
}
