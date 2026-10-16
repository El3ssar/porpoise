import Foundation

public enum DriveError: LocalizedError, Equatable {
    case configuration, reconnect, permissionDenied, notFound, quota, invalidResponse, invalidLocation
    case oauthCancelled, oauthState, oauthTimeout, shortcutCycle, readOnly, unsupportedExport
    case http(Int), keychain(Int32)

    public var errorDescription: String? {
        switch self {
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
            return "This Google document cannot be exported in the selected format. Try another preset or open it in your browser."
        case .http(let code): return "Google Drive request failed (HTTP \(code)). Try again."
        case .keychain(let code): return "Porpoise could not access the account's Keychain credential (\(code))."
        }
    }
}

/// Injectable at the HTTP boundary: fake-server tests exercise the same paging/auth code as production.
public struct DriveHTTP: Sendable {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let send: Send

    public init(
        send: @escaping Send = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw DriveError.invalidResponse }
            return (data, response)
        }
    ) { self.send = send }

    public func response(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        return try await send(request)
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
