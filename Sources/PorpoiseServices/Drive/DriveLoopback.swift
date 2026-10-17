import Foundation

/// Compatibility adapter for Drive's public OAuth errors.
public final class DriveLoopback: CloudSignInListener, @unchecked Sendable {
    private let loopback: CloudOAuthLoopback
    public var redirectURL: URL { loopback.redirectURL }
    public init() throws {
        do { loopback = try CloudOAuthLoopback() } catch { throw driveOAuthError(error) }
    }
    public func cancel() { loopback.cancel() }
    public func finish(_ page: CloudOAuthPage) { loopback.finish(page) }
    public func callback(timeout: TimeInterval = 180) async throws -> URL {
        do { return try await loopback.callback(timeout: timeout) } catch { throw driveOAuthError(error) }
    }
}
