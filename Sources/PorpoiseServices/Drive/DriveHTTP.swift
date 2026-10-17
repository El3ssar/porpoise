import Foundation

public enum DriveError: LocalizedError, Equatable {
    case configuration, reconnect, permissionDenied, notFound, quota, invalidResponse, invalidLocation
    case oauthCancelled, oauthState, oauthTimeout, shortcutCycle, readOnly, unsupportedExport
    case needsWriteAccess, rateLimited, offline, exportTooLarge, safeUpdateUnavailable
    case http(Int), keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .safeUpdateUnavailable:
            return "Automatic saving to Google Drive is not available for this connection yet. Your changes are saved on this Mac."
        case .needsWriteAccess: return "Allow Porpoise to make changes to this Google Drive account."
        case .rateLimited: return "Google Drive is slowing requests. Retrying shortly."
        case .offline: return "Google Drive is offline. Your originals have been kept."
        case .exportTooLarge: return "This Google document is too large to export. Open it in your browser."
        case .configuration: return "Set a Google Desktop OAuth client ID in Settings → Accounts to connect Google Drive."
        case .reconnect: return "Your Google Drive session expired or was revoked. Reconnect this account."
        case .permissionDenied: return "Google Drive denied access. Check the item's sharing and download permissions."
        case .notFound: return "This Drive item is unavailable or you no longer have access."
        case .quota: return "Google Drive is temporarily limiting requests. Try again shortly."
        case .invalidResponse: return "Google Drive returned an invalid response. Try again."
        case .invalidLocation: return "This Google Drive location is invalid."
        case .oauthCancelled: return "Google Drive sign-in was cancelled."
        case .oauthState: return "The sign-in response did not match this request. Try connecting again."
        case .oauthTimeout: return "Google Drive sign-in timed out. Try connecting again."
        case .shortcutCycle: return "This Drive shortcut is cyclic or too deeply nested."
        case .readOnly: return "Google Drive is read-only in this version of Porpoise."
        case .unsupportedExport:
            return "This Google document cannot be exported in this format. Open it in your browser."
        case .http(let code): return "Google Drive request failed (HTTP \(code)). Try again."
        case .keychain(let code): return "Porpoise could not access the account's Keychain credential (\(code))."
        }
    }
}

/// Injectable at the HTTP boundary: fake-server tests exercise the same paging/auth code as production.
public struct DriveHTTP: Sendable {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let send: Send
    private let usesNetworkStream: Bool

    public init(
        send: Send? = nil
    ) {
        usesNetworkStream = send == nil
        self.send =
            send ?? { request in
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw DriveError.invalidResponse }
                return (data, response)
            }
    }

    public func response(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        return try await send(request)
    }

    /// Injected transports retain their response seam; production consumes bounded network buffers.
    func stream(_ request: URLRequest, consume: (Data, HTTPURLResponse) async throws -> Void) async throws -> HTTPURLResponse {
        if usesNetworkStream { return try await HTTPFileStream.receive(request, consume: consume) }
        let (data, response) = try await self.response(request)
        try await consume(data, response)
        return response
    }

    public func data(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await response(request)
        try Self.check(response.statusCode)
        return data
    }

    static func check(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401: throw DriveError.reconnect
        case 403: throw DriveError.permissionDenied
        case 404: throw DriveError.notFound
        case 429: throw DriveError.quota
        default: throw DriveError.http(status)
        }
    }

    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(
            values.sorted { $0.key < $1.key }.map {
                "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
            }.joined(separator: "&").utf8)
    }
}
